"""Conservative, explainable checks, not a claim of semantic fact verification."""

from __future__ import annotations

import re
from collections.abc import Iterator
from typing import cast

SEMANTIC_REVIEW_WARNING = (
    "改写含义待核实：程序无法确认全部语义，请核对完整建议，明确确认事实与修改范围后再保存。"
)


class UnverifiedFactError(ValueError):
    """A fixed, body-free reason plus the affected canonical path for a clarification."""

    def __init__(self, reason: str, *, path: str = "/") -> None:
        super().__init__(reason)
        self.path = path


def populatedFacts(value: object, path: str = "") -> Iterator[tuple[str, object]]:
    if isinstance(value, dict):
        for key, child in cast(dict[str, object], value).items():
            if key not in {"id", "schemaVersion"}:
                yield from populatedFacts(child, path + "/" + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from populatedFacts(child, path + "/" + str(index))
    elif value not in (None, "", False, "unspecified"):
        yield path, value


_numbers = re.compile(r"(?<![\d.])[+-]?\d+(?:\.\d+)?(?:\s*(?:%|％|万|亿|千|百))?")
_technicalTerms = re.compile(r"[A-Za-z][A-Za-z0-9+#.]*")
_responsibilities = (
    re.compile(r"主导|领导|牵头|带领|(?i:\bled\b|\blead\b)"),
    re.compile(r"独立|独自|全权|(?i:\bindependently\b|\bsolely\b)"),
    re.compile(r"负责|管理|(?i:\bmanaged\b|\bresponsible\b)"),
)
_participation = re.compile(
    r"参与|参加|协助|辅助|(?i:\bassisted\b|\bparticipated\b|\bcontributed\s+to\b|\bhelped\b)"
)
_negation = re.compile(r"没有|并未|不是|未曾|并非|未|不|无|没|非$|\bnot\b|\bnever\b", re.I)
_namedMonths = (
    "jan(?:uary)?",
    "feb(?:ruary)?",
    "mar(?:ch)?",
    "apr(?:il)?",
    "may",
    "jun(?:e)?",
    "jul(?:y)?",
    "aug(?:ust)?",
    "sep(?:t(?:ember)?)?",
    "oct(?:ober)?",
    "nov(?:ember)?",
    "dec(?:ember)?",
)


def _supportsNamedDateMonth(source: str, month: int) -> bool:
    if not 1 <= month <= 12:
        return False
    name = _namedMonths[month - 1]
    date = re.compile(rf"\b(?:{name})\.?\s+\d{{4}}\b|\b\d{{4}}\s+(?:{name})\.?(?=\W|$)", re.I)
    return _positiveMatches(date, source)


def validateEducationStart(source: str, year: int, month: int | None) -> None:
    """A graduation date is not evidence of enrollment, even with identical digits."""
    ending = re.compile(r"毕业(?!项目|设计|论文)|\bgraduat(?:ed|ion)\b", re.I)
    if not _positiveMatches(ending, source):
        return
    monthNames = "|".join(_namedMonths)
    dates = re.compile(
        rf"\b(?:{monthNames})\.?\s+(?:19|20|21)\d{{2}}\b|"
        rf"(?<!\d)(?:19|20|21)\d{{2}}\s+(?:{monthNames})\.?(?=\W|$)|"
        r"(?<!\d)(?:19|20|21)\d{2}(?:\s*[年./-]\s*(?:1[0-2]|0?[1-9])(?!\d)\s*月?)?",
        re.I,
    )
    starting = re.compile(r"入学|入读|开始就读|\benrolled\b|\badmitted\b|\bbegan\s+stud", re.I)
    matches = list(dates.finditer(source))
    for index, match in enumerate(matches):
        dateText = match.group()
        if str(year) not in dateText:
            continue
        if month is not None:
            numericMonth = re.search(r"\d{4}\s*[年./-]\s*(\d{1,2})(?!\d)", dateText)
            if not (
                (numericMonth is not None and int(numericMonth.group(1)) == month)
                or _supportsNamedDateMonth(dateText, month)
            ):
                continue
        # Stop at another date or clause, so starting a job in an unrelated clause
        # cannot supply this education's enrollment date.
        precedingEnd = matches[index - 1].end() if index else 0
        prefix = re.split(r"[，,；;。\n]", source[precedingEnd : match.start()])[-1]
        starts = list(starting.finditer(prefix))
        ends = list(ending.finditer(prefix))
        if starts and (not ends or starts[-1].start() > ends[-1].start()):
            beforeStart = prefix[max(0, starts[-1].start() - 12) : starts[-1].start()]
            afterStart = prefix[starts[-1].end() :]
            if _negation.search(beforeStart + afterStart) is None:
                return
        followingStart = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        suffix = source[match.end() : followingStart]
        if re.match(r"\s*(?:入学|入读|开始就读)", suffix):
            return
        if index + 1 < len(matches) and re.fullmatch(r"\s*年?\s*[-—–~至到]\s*", suffix):
            return
    raise UnverifiedFactError("事实校验：毕业日期不能作为未提供的入学日期")


def _positiveMatches(pattern: re.Pattern[str], text: str) -> bool:
    return any(
        _negation.search(re.split(r"[，,；;。\n]", text[: match.start()])[-1][-12:]) is None
        for match in pattern.finditer(text)
    )


def _numberSet(text: str) -> set[str]:
    # Leading zero/date formatting is not a changed numeric fact.
    result = set()
    for number in _numbers.findall(text):
        number = re.sub(r"\s", "", number).replace("％", "%")
        integer, dot, fraction = number.partition(".")
        result.add((integer.lstrip("0") or "0") + dot + fraction)
    return result


def validateFactText(source: str, candidate: str, *, preserveExisting: bool = False) -> None:
    sourceNumbers, candidateNumbers = _numberSet(source), _numberSet(candidate)
    if not candidateNumbers <= sourceNumbers or (
        preserveExisting and sourceNumbers != candidateNumbers
    ):
        raise UnverifiedFactError("事实校验：数字或日期与来源不一致")
    sourceTerms = {term.casefold().rstrip(".") for term in _technicalTerms.findall(source)}
    candidateTerms = {term.casefold().rstrip(".") for term in _technicalTerms.findall(candidate)}
    # Applies to mixed Chinese/technical text. General English prose needs semantic review,
    # not a word-subset rule that would reject every English synonym.
    if re.search(r"[\u4e00-\u9fff]", source) and not candidateTerms <= sourceTerms:
        raise UnverifiedFactError("事实校验：新增外文实体或技术名词缺少来源")
    for responsibility in _responsibilities:
        if _positiveMatches(responsibility, candidate) and not _positiveMatches(
            responsibility, source
        ):
            raise UnverifiedFactError("事实校验：职责程度超出来源")
    if (
        preserveExisting
        and _positiveMatches(_participation, source)
        and not _positiveMatches(_participation, candidate)
    ):
        raise UnverifiedFactError("事实校验：不得删除参与或协助的职责限定")


def isSupportedRewording(source: str, candidate: str) -> bool:
    """Permit extraction and a deliberately small set of harmless wording changes.

    Arbitrary fluent rewrites are not classified as true by another model or a lexical
    similarity score. The caller instead asks the user to confirm the complete facts.
    """

    def normalized(text: str) -> str:
        text = text.casefold().replace("参加", "参与")
        # Keep English word boundaries so "not a native speaker" cannot support
        # "native speaker" after whitespace normalization.
        return " ".join(re.sub(r"[，,。.;；:：、的了]", "", text).split())

    wanted = normalized(candidate)
    if not wanted:
        return False
    for clause in re.split(r"[。;；\n]", source):
        available = normalized(clause)
        start = available.find(wanted)
        if start >= 0 and _negation.search(available[max(0, start - 8) : start]) is None:
            return True
    return False


def validateLiteralFact(path: str, value: object, source: str) -> None:
    if isinstance(value, str):
        if path.endswith("/proficiency"):
            proficiencyEvidence = {
                "native": r"母语|\bnative\b",
                "fluent": r"流利|\bfluent\b",
                "professional": r"专业水平|工作熟练|\bprofessional\b",
                "intermediate": r"中级|\bintermediate\b",
                "basic": r"初级|基础水平|\bbasic\b",
            }
            if not _positiveMatches(
                re.compile(proficiencyEvidence.get(value, r"(?!)"), re.I), source
            ):
                raise UnverifiedFactError("事实校验：语言熟练程度缺少来源")
            return
        validateFactText(source, value)
        field = path.rsplit("/", 1)[-1]
        exactFields = {
            "organization",
            "position",
            "institution",
            "degree",
            "fieldOfStudy",
            "role",
            "name",
            "issuer",
            "coarseLocation",
            "fullName",
            "phone",
            "email",
            "preciseAddress",
        }
        if (
            (field in exactFields or "/skills/" in path)
            and value.casefold() not in source.casefold()
            and not (
                # Fixed layout labels assert neither an actual project name nor a skill.
                (re.fullmatch(r"/projects/[0-9]+/name", path) and value == "项目经历")
                or (re.fullmatch(r"/skillGroups/[0-9]+/name", path) and value == "技能")
            )
        ):
            raise UnverifiedFactError("事实校验：实体或资格原文缺少来源")
    elif isinstance(value, int) and not isinstance(value, bool):
        # A written calendar month can become a structured month number. Keep this
        # exception on date fields; it must not authorize a new headcount/metric.
        if re.search(r"/(?:start|end|date)/month$", path) and _supportsNamedDateMonth(
            source, value
        ):
            return
        if str(value) not in _numberSet(source):
            raise UnverifiedFactError("事实校验：日期缺少来源")
    elif value is True:
        currentEvidence = re.compile(r"至今|在职|任职中|\bcurrent\b|\bpresent\b", re.I)
        if not _positiveMatches(currentEvidence, source) or re.search(
            r"已离职|未就业|已结束|不再", source
        ):
            raise UnverifiedFactError("事实校验：当前任职状态缺少来源")
