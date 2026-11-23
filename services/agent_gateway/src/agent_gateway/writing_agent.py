"""One bounded writing turn: compile intent, minimize context, enforce the user's scope.

The Gateway owns authentication/idempotency and the client owns version review/commit.
This module neither calls a model nor writes a resume. It intentionally preserves the
original words when deterministic translation cannot establish their full meaning.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import cast

from .remote_contracts import (
    BasicResumeComposeInput,
    BasicResumeComposeOutput,
    CandidateSourceReference,
    MissingInformation,
    RemoteResumeAiOutput,
    RemoteResumeAiRequest,
    ResumeDataProjection,
    ResumeOptimizationConversationInput,
    ResumeOptimizationConversationOutput,
    TargetedResumeOptimizationInput,
    TargetedResumeOptimizationOutput,
    permittedPatchPaths,
)

WRITING_RULES_VERSION = "resume-writing-agent.v4"
FACT_REVIEW_WARNING = (
    "事实检查仅覆盖来源、字段及明显数字/职责变化；请逐项核对语义和经历后再确认保存。"
)


@dataclass(frozen=True, slots=True)
class PreparedWritingTask:
    providerInput: dict[str, object]
    allowedPaths: tuple[str, ...]
    clarificationQuestion: str | None


_scopes = {
    "项目描述": r"/projects/\d+/summary",
    "项目简介": r"/projects/\d+/summary",
    "项目": r"/projects/.*",
    "工作总结": r"/workExperiences/\d+/summary",
    "工作描述": r"/workExperiences/\d+/summary",
    "工作经历": r"/workExperiences/.*",
    "个人简介": r"/profile/headline",
    "简介": r"/profile/headline",
    "意向岗位": r"/profile/headline",
    "求职意向": r"/profile/headline",
    "技能": r"(?!)",
    "日期": r"(?!)",
    "公司": r"(?!)",
    "姓名": r"(?!)",
    "学历": r"(?!)",
    "project description": r"/projects/\d+/summary",
    "project summary": r"/projects/\d+/summary",
    "work summary": r"/workExperiences/\d+/summary",
    "headline": r"/profile/headline",
    "dates": r"(?!)",
}
_scopeInstruction = re.compile(
    r"^(?:请帮我|帮我|请)?(只|仅|就|不要|别|不得|不许)(?:修改|改|优化|润色|动)(.+)$"
)
_unresolvedScopeInstruction = re.compile(
    r"(?:只|仅)(?:把|将|对|改|修改|优化|润色)|"
    r"(?:不要|别|不得|不许)(?:改|修改|优化|润色|动|删|删除|添加)|别动|\bonly\b",
    re.I,
)


def _scopeClause(clause: str) -> tuple[str, str] | None:
    clause = re.sub(r"(?:一下|吧|就好)$", "", clause.strip()).casefold()
    for scope in sorted(_scopes, key=len, reverse=True):
        colloquial = re.fullmatch(
            r"(?:请)?(只|仅)(?:把|将)" + re.escape(scope) + r"(?:写|改|调整|整理|优化|润色|变).+",
            clause,
        )
        if colloquial:
            return colloquial.group(1), scope
    match = _scopeInstruction.fullmatch(clause)
    if match:
        return match.group(1), match.group(2)
    match = re.fullmatch(r"(?:请)?(?:只|仅)对(.+?)(?:修改|改|优化|润色)", clause)
    if match:
        return "只", match.group(1)
    match = re.fullmatch(r"(.+?)可以改", clause)
    if match:
        return "只", match.group(1)
    match = re.fullmatch(
        r"(?:please )?(only|do not|don't) (?:edit|change|rewrite) (?:the )?(.+)", clause
    )
    if match:
        return ("只" if match.group(1) == "only" else "不要"), match.group(2)
    return None


def _languageAndStyle(instructions: list[str]) -> tuple[str, str]:
    language, style = "preserve", "preserve"
    for instruction in instructions:
        for clause in re.split(r"[，,；;。\n]", instruction):
            clause = clause.strip()
            if re.fullmatch(r"(?:请)?(?:保持|使用|用)中文", clause):
                language = "zh"
            elif re.fullmatch(r"(?:请)?(?:保持|使用|用)英文", clause):
                language = "en"
            elif re.fullmatch(r"(?:不要|别)(?:保持|使用|用)(?:中文|英文)", clause):
                language = "preserve"
            if re.fullmatch(r"(?:请)?(?:写得|写|更)专业(?:一点|些)?", clause):
                style = "professional"
            elif re.fullmatch(r"(?:不要|别)(?:写得|写|更)专业(?:一点|些)?", clause):
                style = "preserve"
    return language, style


def prepareWritingTask(request: RemoteResumeAiRequest) -> PreparedWritingTask:
    projected = cast(dict[str, object], request.input.model_dump(mode="json", exclude_none=True))
    projected.pop("baseResumeFingerprint", None)
    projected.pop("conversationToken", None)
    personalData = projected.get("personalData")
    if isinstance(personalData, dict):
        cast(dict[str, object], personalData).pop("consentedFields", None)
    instruction = ""
    historyInstructions: list[str] = []
    allowedPaths: tuple[str, ...] = ()
    clarification: str | None = None
    if isinstance(request.input, BasicResumeComposeInput):
        if all(
            re.fullmatch(
                r"(?:请|帮我|请帮我)?(?:写|生成|制作)(?:一份)?(?:简历|履历)[吧。！!]*|不知道写什么",
                fragment.text,
            )
            for fragment in request.input.sourceFragments
        ):
            clarification = "请先提供真实的工作、项目、教育或技能材料；仅有写作要求无法生成事实。"
    else:
        allowedPaths = permittedPatchPaths(request.input.resume)
        if isinstance(request.input, ResumeOptimizationConversationInput):
            instruction = request.input.userMessage
            historyInstructions = [
                message.content
                for message in request.input.recentMessages
                if message.role == "user"
            ]
            projected.pop("userMessage", None)
        else:
            instruction = request.input.userInstruction
            projected.pop("userInstruction", None)
        context = request.input.writingContext
        if context is not None:
            historyInstructions = [*context.constraints, *historyInstructions]
            # Explicitly confirmed text can fill an existing empty text field, but cannot
            # create an entity or expand the contract's immutable-field boundary.
            allowedPaths = tuple(
                dict.fromkeys((*allowedPaths, *(fact.path for fact in context.confirmedFacts)))
            )
            projectedContext = cast(dict[str, object], projected["writingContext"])
            projectedContext.pop("baseResumeFingerprint", None)
        includedScopes: set[str] = set()
        excludedScopes: set[str] = set()
        for sourceInstruction in [*historyInstructions, instruction]:
            turnScopes: set[str] = set()
            scopeSelections: set[frozenset[str]] = set()
            turnClarification: str | None = None
            for clause in re.split(r"[，,；;。\n]", sourceInstruction):
                if re.fullmatch(
                    r"(?:别动|不要改|不要动)其他部分|其他部分(?:不要动|不要改)", clause.strip()
                ):
                    if not turnScopes:
                        turnClarification = "请先说明需要修改的部分，再保留其他部分不变。"
                    continue
                selection = _scopeClause(clause)
                if selection is None:
                    # Colloquial facts ("仅参与过") and safeguards ("不要夸大经历")
                    # are not ambiguous edit scopes. Preserve them verbatim for the model.
                    if _unresolvedScopeInstruction.search(clause):
                        turnClarification = (
                            "请明确本轮要修改或保留的部分；未明确前不生成可应用修改。"
                        )
                    continue
                mode, scope = selection
                scopeNames = (
                    re.split(r"以及|、|和|与|及|\band\b", scope, flags=re.I)
                    if mode in {"只", "仅", "就"}
                    else re.split(r"或者|以及|、|和|与|及|或", scope)
                )
                expressions = [_scopes.get(name.strip()) for name in scopeNames]
                if any(expression is None for expression in expressions):
                    turnClarification = (
                        "请明确要修改或保留的部分，例如“只改项目描述”；未明确前不生成可应用修改。"
                    )
                elif mode in {"只", "仅", "就"}:
                    selectionScopes = frozenset(
                        expression for expression in expressions if expression is not None
                    )
                    scopeSelections.add(selectionScopes)
                    turnScopes.update(selectionScopes)
                else:
                    excludedScopes.update(
                        expression for expression in expressions if expression is not None
                    )
            if turnScopes:
                # A later explicit selection resolves an earlier vague selection. Historic
                # prohibitions are retained; an ambiguous expansion still asks the user.
                includedScopes = turnScopes
                clarification = turnClarification
            elif turnClarification:
                clarification = turnClarification
            if len(scopeSelections) > 1:
                clarification = "同一轮要求涉及不同的限定范围，请明确本轮要修改哪一部分。"
        if clarification:
            allowedPaths = ()
        else:
            allowedPaths = tuple(
                path
                for path in allowedPaths
                if (
                    not includedScopes or any(re.fullmatch(scope, path) for scope in includedScopes)
                )
                and not any(re.fullmatch(scope, path) for scope in excludedScopes)
            )
            if not allowedPaths:
                clarification = (
                    "当前所选范围没有可改写的已确认文本，或与保留要求冲突。请补充事实或明确范围。"
                )
        # Only remove unrelated sections when the user explicitly selected a known scope.
        # Keep array positions and every original value inside retained sections intact.
        if includedScopes:
            sections = {path.split("/")[1] for path in allowedPaths}
            resume = cast(dict[str, object], projected["resume"])
            projected["resume"] = {
                key: value
                for key, value in resume.items()
                if key in sections or key == "schemaVersion"
            }
        if context is not None:
            projectedContext["confirmedFacts"] = [
                fact.model_dump(mode="json")
                for fact in context.confirmedFacts
                if fact.path in allowedPaths
            ]

    language, style = _languageAndStyle([*historyInstructions, instruction])
    projected = cast(dict[str, object], _withoutEmptyDefaults(projected))
    projected["task"] = {
        "rulesVersion": WRITING_RULES_VERSION,
        "intent": "organizeProvidedFacts"
        if isinstance(request.input, BasicResumeComposeInput)
        else "improveWording",
        "originalInstruction": instruction,
        "allowedPaths": list(allowedPaths),
        "outputLanguage": language,
        "style": style,
        "clarificationQuestion": clarification,
    }
    return PreparedWritingTask(projected, allowedPaths, clarification)


def _withoutEmptyDefaults(value: object) -> object:
    if isinstance(value, dict):
        return {
            key: _withoutEmptyDefaults(child)
            for key, child in cast(dict[str, object], value).items()
            if child is not None and child != "" and child != []
        }
    if isinstance(value, list):
        return [_withoutEmptyDefaults(child) for child in value]
    return value


def validateWritingScope(output: RemoteResumeAiOutput, task: PreparedWritingTask) -> None:
    patch = getattr(output, "proposedPatch", None)
    if patch is not None:
        for operation in patch.operations:
            if operation.path not in task.allowedPaths:
                raise ValueError("用户修改范围校验：模型修改超出本轮允许范围")
    if task.clarificationQuestion and not output.missingInformation:
        raise ValueError("用户修改范围校验：范围不明确时必须先追问")


def writingClarification(
    request: RemoteResumeAiRequest, task: PreparedWritingTask
) -> RemoteResumeAiOutput | None:
    if not task.clarificationQuestion:
        return None
    question = MissingInformation(path="/", question=task.clarificationQuestion)
    return _questionOutput(request, question)


def writingFactClarification(request: RemoteResumeAiRequest, path: str) -> RemoteResumeAiOutput:
    question = MissingInformation(
        path=path,
        question="这部分的事实或改写含义尚不能确认。请核实完整真实内容后继续；不要直接接受模型补造的内容。",
    )
    return _questionOutput(request, question)


def requireAnswersBeforeCandidate(
    output: RemoteResumeAiOutput, request: RemoteResumeAiRequest
) -> RemoteResumeAiOutput:
    if not output.missingInformation:
        return output
    # Do not return half of a candidate alongside unresolved questions. The user must
    # confirm the facts in a new intentional turn; there is no automatic repair request.
    questionsOnly = _questionOutput(request, output.missingInformation[0])
    return questionsOnly.model_copy(
        update={
            "missingInformation": output.missingInformation,
            "warnings": tuple(dict.fromkeys((*questionsOnly.warnings, *output.warnings)))[:20],
        }
    )


def _questionOutput(
    request: RemoteResumeAiRequest, question: MissingInformation
) -> RemoteResumeAiOutput:
    if isinstance(request.input, BasicResumeComposeInput):
        return BasicResumeComposeOutput(
            outputVersion="basicResumeCompose.v1",
            summary="请先补充并确认真实材料",
            candidateResume=ResumeDataProjection.model_validate(
                {
                    "schemaVersion": "0.1.0",
                    "profile": {"id": "candidate-profile"},
                }
            ),
            sourceReferences=(
                CandidateSourceReference(
                    path="/profile",
                    fragmentIds=(request.input.sourceFragments[0].fragmentId,),
                ),
            ),
            missingInformation=(question,),
            warnings=("本次仅提出问题，没有可保存的简历候选。",),
        )
    if isinstance(request.input, TargetedResumeOptimizationInput):
        return TargetedResumeOptimizationOutput(
            outputVersion="targetedResumeOptimization.v1",
            summary="请先补充或确认本轮材料与要求",
            missingInformation=(question,),
            nextAction="provideMoreInformation",
        )
    if isinstance(request.input, ResumeOptimizationConversationInput):
        return ResumeOptimizationConversationOutput(
            outputVersion="resumeOptimizationConversation.v1",
            summary="请先补充或确认本轮材料与要求",
            missingInformation=(question,),
            nextAction="provideMoreInformation",
        )
    raise ValueError("不支持的写作任务类型")
