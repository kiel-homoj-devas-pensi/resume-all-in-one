import pytest

from agent_gateway.remote_contracts import (
    BasicResumeComposeInput,
    BasicResumeComposeOutput,
    validateBasicComposeOutput,
)
from agent_gateway.resume_fact_guard import UnverifiedFactError, validateLiteralFact


@pytest.mark.parametrize(
    ("source", "month"),
    [
        ("I worked from March 2022 to May 2024.", 3),
        ("I worked from March 2022 to May 2024.", 5),
        ("Started in JANUARY 2023.", 1),
        ("Ended in Sep. 2024.", 9),
        ("Ended in 2024 December.", 12),
    ],
)
def test_named_calendar_month_supports_only_a_date_month(source: str, month: int) -> None:
    validateLiteralFact("/workExperiences/0/period/start/month", month, source)
    with pytest.raises(UnverifiedFactError):
        validateLiteralFact("/projects/0/headcount", month, source)


@pytest.mark.parametrize(
    "source",
    [
        "I used the March framework in 2022.",
        "The month may have been March, but the year is unknown.",
        "Not March 2022; I do not remember when.",
        "Worked in May 2022.",
        "Worked in March 22.",
    ],
)
def test_unsupported_or_negated_calendar_month_still_rejected(source: str) -> None:
    with pytest.raises(UnverifiedFactError):
        validateLiteralFact("/workExperiences/0/period/start/month", 3, source)


def _educationCandidate(
    source: str, *, start: dict[str, int] | None = None
) -> tuple[BasicResumeComposeInput, BasicResumeComposeOutput]:
    request = BasicResumeComposeInput.model_validate(
        {
            "inputType": "basicResumeCompose",
            "sourceFragments": [{"fragmentId": "education-1", "text": source}],
        }
    )
    output = BasicResumeComposeOutput.model_validate(
        {
            "outputVersion": "basicResumeCompose.v1",
            "summary": "保留教育来源事实，未知入学时间不补造",
            "candidateResume": {
                "schemaVersion": "0.1.0",
                "profile": {"id": "candidate-profile"},
                "educations": [
                    {
                        "id": "candidate-education-1",
                        "institution": "示例大学",
                        "dateRange": (
                            {"start": start, "end": {"year": 2024, "month": 6}}
                            if start is not None
                            else None
                        ),
                        "highlights": [source],
                    }
                ],
            },
            "sourceReferences": [{"path": "/educations/0", "fragmentIds": ["education-1"]}],
        }
    )
    return request, output


@pytest.mark.parametrize(
    "source",
    [
        "2024年6月毕业于示例大学。",
        "Graduated from 示例大学 in June 2024.",
        "2024年毕业于示例大学，月份不记得。",
    ],
)
def test_graduation_only_can_be_delivered_without_inventing_enrollment(source: str) -> None:
    request, output = _educationCandidate(source)
    assert validateBasicComposeOutput(output, request) is False
    education = output.candidateResume.educations[0]
    assert education.dateRange is None
    assert education.highlights == (source,)
    assert output.missingInformation == ()


@pytest.mark.parametrize(
    "source",
    [
        "2024年6月毕业于示例大学。",
        "Graduated from 示例大学 in June 2024.",
    ],
)
def test_graduation_date_cannot_also_supply_unknown_enrollment(source: str) -> None:
    request, output = _educationCandidate(source, start={"year": 2024, "month": 6})
    with pytest.raises(UnverifiedFactError):
        validateBasicComposeOutput(output, request, allowSemanticReview=True)


@pytest.mark.parametrize(
    "source",
    [
        "2024年6月入学，2024年6月毕业于示例大学。",
        "Enrolled in 示例大学 in June 2024 and graduated in June 2024.",
    ],
)
def test_explicit_same_month_enrollment_and_graduation_remain_valid(source: str) -> None:
    request, output = _educationCandidate(source, start={"year": 2024, "month": 6})
    assert validateBasicComposeOutput(output, request) is False


@pytest.mark.parametrize(
    "source",
    [
        "2020年9月入学，2024年6月毕业于示例大学。",
        "入学时间未提供，2024年6月毕业于示例大学。",
        "2020年入职示例公司，2024年6月毕业于示例大学。",
        "Enrolled in September 2020 and graduated from 示例大学 in June 2024.",
    ],
)
def test_other_date_or_unprovided_enrollment_cannot_support_graduation_as_start(
    source: str,
) -> None:
    request, output = _educationCandidate(source, start={"year": 2024, "month": 6})
    with pytest.raises(UnverifiedFactError):
        validateBasicComposeOutput(output, request, allowSemanticReview=True)
