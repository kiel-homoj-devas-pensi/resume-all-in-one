from __future__ import annotations

import re
from typing import Annotated, Literal, cast

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from .resume_fact_guard import (
    UnverifiedFactError,
    isSupportedRewording,
    populatedFacts,
    validateEducationStart,
    validateFactText,
    validateLiteralFact,
)
from .usage import ProductCapability

RemoteProtocolVersion = Literal["0.3.0"]
EntityId = Annotated[
    str,
    StringConstraints(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]*$",
    ),
]
ShortText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
MediumText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=1000)]
OptionalShortText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
OptionalMediumText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)]


class StrictRemoteModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class ResumeDateProjection(StrictRemoteModel):
    year: int = Field(ge=1900, le=2200)
    month: int | None = Field(default=None, ge=1, le=12)


class DateRangeProjection(StrictRemoteModel):
    start: ResumeDateProjection
    end: ResumeDateProjection | None = None
    isCurrent: bool = False

    @model_validator(mode="after")
    def validateDateRange(self) -> DateRangeProjection:
        if self.isCurrent and self.end is not None:
            raise ValueError("当前经历不能包含结束日期")
        if self.end is not None:
            startMonth = self.start.month or 1
            endMonth = self.end.month or 12
            if (self.end.year, endMonth) < (self.start.year, startMonth):
                raise ValueError("结束日期不能早于开始日期")
        return self


class ResumeProfileProjection(StrictRemoteModel):
    id: EntityId
    headline: OptionalShortText = ""
    coarseLocation: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = ""


class WorkExperienceProjection(StrictRemoteModel):
    id: EntityId
    organization: OptionalShortText = ""
    position: OptionalShortText = ""
    dateRange: DateRangeProjection | None = None
    summary: OptionalMediumText = ""
    highlights: tuple[MediumText, ...] = Field(default=(), max_length=20)


class EducationProjection(StrictRemoteModel):
    id: EntityId
    institution: OptionalShortText = ""
    degree: OptionalShortText = ""
    fieldOfStudy: OptionalShortText = ""
    dateRange: DateRangeProjection | None = None
    highlights: tuple[MediumText, ...] = Field(default=(), max_length=20)


class ProjectExperienceProjection(StrictRemoteModel):
    id: EntityId
    name: OptionalShortText = ""
    role: OptionalShortText = ""
    dateRange: DateRangeProjection | None = None
    summary: OptionalMediumText = ""
    highlights: tuple[MediumText, ...] = Field(default=(), max_length=20)


class SkillGroupProjection(StrictRemoteModel):
    id: EntityId
    name: OptionalShortText = ""
    skills: tuple[ShortText, ...] = Field(default=(), max_length=30)


class CertificationProjection(StrictRemoteModel):
    id: EntityId
    name: OptionalShortText = ""
    issuer: OptionalShortText = ""
    issuedOn: ResumeDateProjection | None = None
    expiresOn: ResumeDateProjection | None = None


LanguageProficiency = Literal[
    "native",
    "fluent",
    "professional",
    "intermediate",
    "basic",
    "unspecified",
]


class LanguageProjection(StrictRemoteModel):
    id: EntityId
    name: OptionalShortText = ""
    proficiency: LanguageProficiency = "unspecified"


class CustomSectionItemProjection(StrictRemoteModel):
    id: EntityId
    title: OptionalShortText = ""
    description: OptionalMediumText = ""


class CustomSectionProjection(StrictRemoteModel):
    id: EntityId
    title: OptionalShortText = ""
    items: tuple[CustomSectionItemProjection, ...] = Field(default=(), max_length=20)


class ResumeDataProjection(StrictRemoteModel):
    schemaVersion: Literal["0.1.0"]
    profile: ResumeProfileProjection
    workExperiences: tuple[WorkExperienceProjection, ...] = Field(default=(), max_length=30)
    educations: tuple[EducationProjection, ...] = Field(default=(), max_length=20)
    projects: tuple[ProjectExperienceProjection, ...] = Field(default=(), max_length=30)
    skillGroups: tuple[SkillGroupProjection, ...] = Field(default=(), max_length=20)
    certifications: tuple[CertificationProjection, ...] = Field(default=(), max_length=20)
    languages: tuple[LanguageProjection, ...] = Field(default=(), max_length=20)
    customSections: tuple[CustomSectionProjection, ...] = Field(default=(), max_length=20)


PersonalFieldName = Literal["fullName", "phone", "email", "preciseAddress"]


class PersonalDataProjection(StrictRemoteModel):
    consentedFields: tuple[PersonalFieldName, ...] = Field(min_length=1, max_length=4)
    fullName: (
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
        | None
    ) = None
    phone: (
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=32)] | None
    ) = None
    email: (
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=254)]
        | None
    ) = None
    preciseAddress: (
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
        | None
    ) = None

    @model_validator(mode="after")
    def requireExactFieldConsent(self) -> PersonalDataProjection:
        if len(set(self.consentedFields)) != len(self.consentedFields):
            raise ValueError("consentedFields 不能重复")
        suppliedFields = {
            fieldName
            for fieldName in ("fullName", "phone", "email", "preciseAddress")
            if getattr(self, fieldName) is not None
        }
        if suppliedFields != set(self.consentedFields):
            raise ValueError("consentedFields 必须与本次实际发送的个人字段完全一致")
        return self


FragmentCategory = Literal[
    "unspecified",
    "profile",
    "work",
    "education",
    "project",
    "skill",
    "certification",
    "language",
    "custom",
]


class ResumeSourceFragment(StrictRemoteModel):
    fragmentId: EntityId
    category: FragmentCategory = "unspecified"
    text: MediumText


class BasicResumeComposeInput(StrictRemoteModel):
    inputType: Literal["basicResumeCompose"]
    sourceFragments: tuple[ResumeSourceFragment, ...] = Field(min_length=1, max_length=40)
    personalData: PersonalDataProjection | None = None
    naturalLanguageInput: bool = False

    @model_validator(mode="after")
    def validateFragments(self) -> BasicResumeComposeInput:
        fragmentIds = [fragment.fragmentId for fragment in self.sourceFragments]
        if len(set(fragmentIds)) != len(fragmentIds):
            raise ValueError("fragmentId 必须唯一")
        if sum(len(fragment.text) for fragment in self.sourceFragments) > 20_000:
            raise ValueError("文本碎片总长度不能超过 20000 字符")
        return self


class ConfirmedWritingFact(StrictRemoteModel):
    path: Annotated[str, StringConstraints(pattern=r"^/", max_length=256)]
    text: MediumText


class WritingContext(StrictRemoteModel):
    baseResumeFingerprint: Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{64}$")]
    confirmedFacts: tuple[ConfirmedWritingFact, ...] = Field(default=(), max_length=12)
    constraints: tuple[
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)], ...
    ] = Field(default=(), max_length=12)

    @model_validator(mode="after")
    def validateContextLimits(self) -> WritingContext:
        if len({fact.path for fact in self.confirmedFacts}) != len(self.confirmedFacts):
            raise ValueError("同一文本字段只能提供一份已确认事实")
        if sum(len(fact.text) for fact in self.confirmedFacts) > 6000:
            raise ValueError("已确认事实总长度不能超过6000字符")
        if sum(len(constraint) for constraint in self.constraints) > 3000:
            raise ValueError("长期要求总长度不能超过3000字符")
        return self


class TargetedResumeOptimizationInput(StrictRemoteModel):
    inputType: Literal["targetedResumeOptimization"]
    baseResumeFingerprint: Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{64}$")]
    resume: ResumeDataProjection
    targetJobTitle: Annotated[
        str,
        StringConstraints(strip_whitespace=True, max_length=100),
    ] = ""
    jobDescription: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] = ""
    userInstruction: Annotated[str, StringConstraints(strip_whitespace=True, max_length=4000)] = ""
    personalData: PersonalDataProjection | None = None
    writingContext: WritingContext | None = None
    allowSemanticReview: bool = False

    @model_validator(mode="after")
    def validateWritingContext(self) -> TargetedResumeOptimizationInput:
        if not (self.targetJobTitle or self.jobDescription or self.userInstruction):
            raise ValueError("请描述希望如何改进简历，或提供目标岗位")
        _validateWritingContext(self.writingContext, self.baseResumeFingerprint, self.resume)
        return self


class ConversationMessage(StrictRemoteModel):
    role: Literal["user", "assistant"]
    content: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=4000)]


class ResumeOptimizationConversationInput(StrictRemoteModel):
    inputType: Literal["resumeOptimizationConversation"]
    conversationToken: EntityId
    baseResumeFingerprint: Annotated[str, StringConstraints(pattern=r"^[a-f0-9]{64}$")]
    resume: ResumeDataProjection
    targetJobTitle: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = ""
    jobDescription: Annotated[str, StringConstraints(strip_whitespace=True, max_length=2000)] = ""
    recentMessages: tuple[ConversationMessage, ...] = Field(default=(), max_length=6)
    userMessage: Annotated[
        str,
        StringConstraints(strip_whitespace=True, min_length=1, max_length=4000),
    ]
    personalData: PersonalDataProjection | None = None
    writingContext: WritingContext | None = None
    allowSemanticReview: bool = False

    @model_validator(mode="after")
    def validateWritingContext(self) -> ResumeOptimizationConversationInput:
        if sum(len(message.content) for message in self.recentMessages) > 8000:
            raise ValueError("最近对话上下文不能超过8000字符")
        _validateWritingContext(self.writingContext, self.baseResumeFingerprint, self.resume)
        return self


type RemoteResumeInput = Annotated[
    BasicResumeComposeInput | TargetedResumeOptimizationInput | ResumeOptimizationConversationInput,
    Field(discriminator="inputType"),
]


class RemoteResumeAiRequest(StrictRemoteModel):
    protocolVersion: RemoteProtocolVersion
    clientRequestId: EntityId
    idempotencyKey: Annotated[str, StringConstraints(min_length=1, max_length=256)]
    capability: ProductCapability
    input: RemoteResumeInput

    @model_validator(mode="after")
    def requireMatchingCapability(self) -> RemoteResumeAiRequest:
        if self.capability.value != self.input.inputType:
            raise ValueError("capability 必须与 inputType 一致")
        return self


class MissingInformation(StrictRemoteModel):
    path: Annotated[str, StringConstraints(min_length=1, max_length=256)]
    question: ShortText


class CandidateSourceReference(StrictRemoteModel):
    path: Annotated[str, StringConstraints(pattern=r"^/", max_length=256)]
    fragmentIds: tuple[EntityId, ...] = Field(min_length=1, max_length=20)


class ComposedProfileProjection(ResumeProfileProjection):
    fullName: Annotated[str, StringConstraints(max_length=100)] = ""
    phone: Annotated[str, StringConstraints(max_length=32)] = ""
    email: Annotated[str, StringConstraints(max_length=254)] = ""
    preciseAddress: Annotated[str, StringConstraints(max_length=200)] = ""


class ComposedResumeDataProjection(ResumeDataProjection):
    profile: ComposedProfileProjection


class BasicResumeComposeOutput(StrictRemoteModel):
    outputVersion: Literal["basicResumeCompose.v1"]
    summary: ShortText
    candidateResume: ResumeDataProjection | ComposedResumeDataProjection
    sourceReferences: tuple[CandidateSourceReference, ...] = Field(min_length=1, max_length=100)
    missingInformation: tuple[MissingInformation, ...] = Field(default=(), max_length=30)
    warnings: tuple[ShortText, ...] = Field(default=(), max_length=20)


class ResumePatchOperation(StrictRemoteModel):
    type: Literal["replace"]
    path: Annotated[str, StringConstraints(pattern=r"^/", max_length=256)]
    oldValue: OptionalMediumText
    newValue: MediumText
    reason: ShortText
    source: Literal["remoteAi"]
    category: Literal["wording", "format"]

    @model_validator(mode="after")
    def rejectNoOp(self) -> ResumePatchOperation:
        if self.oldValue == self.newValue:
            raise ValueError("Patch 不能用相同文本替换原值")
        return self


class RemoteResumePatch(StrictRemoteModel):
    operations: tuple[ResumePatchOperation, ...] = Field(min_length=1, max_length=12)


class TargetedResumeOptimizationOutput(StrictRemoteModel):
    outputVersion: Literal["targetedResumeOptimization.v1"]
    summary: ShortText
    proposedPatch: RemoteResumePatch | None = None
    missingInformation: tuple[MissingInformation, ...] = Field(default=(), max_length=20)
    warnings: tuple[ShortText, ...] = Field(default=(), max_length=20)
    nextAction: Literal["reviewPatch", "provideMoreInformation", "none"]


class ResumeOptimizationConversationOutput(StrictRemoteModel):
    outputVersion: Literal["resumeOptimizationConversation.v1"]
    summary: ShortText
    proposedPatch: RemoteResumePatch | None = None
    missingInformation: tuple[MissingInformation, ...] = Field(default=(), max_length=20)
    warnings: tuple[ShortText, ...] = Field(default=(), max_length=20)
    nextAction: Literal["reviewPatch", "provideMoreInformation", "none"]


type RemoteResumeAiOutput = Annotated[
    BasicResumeComposeOutput
    | TargetedResumeOptimizationOutput
    | ResumeOptimizationConversationOutput,
    Field(discriminator="outputVersion"),
]


class RemoteExecutionMetadata(StrictRemoteModel):
    usesNetwork: bool
    promptVersion: str


class RemoteResumeAiSuccessResponse(StrictRemoteModel):
    protocolVersion: RemoteProtocolVersion = "0.3.0"
    operationId: str
    clientRequestId: str
    capability: ProductCapability
    status: Literal["succeeded"] = "succeeded"
    output: RemoteResumeAiOutput
    execution: RemoteExecutionMetadata


_allowedPatchPath = re.compile(
    r"^(?:"
    r"/profile/headline|"
    r"/workExperiences/[0-9]+/(?:summary|highlights/[0-9]+)|"
    r"/educations/[0-9]+/highlights/[0-9]+|"
    r"/projects/[0-9]+/(?:summary|highlights/[0-9]+)|"
    r"/customSections/[0-9]+/items/[0-9]+/(?:title|description)"
    r")$"
)


def _validateWritingContext(
    context: WritingContext | None, fingerprint: str, resume: ResumeDataProjection
) -> None:
    if context is None:
        return
    if context.baseResumeFingerprint != fingerprint:
        raise ValueError("写作上下文与本轮简历基础版本不一致")
    resumeJson = resume.model_dump(mode="json")
    for fact in context.confirmedFacts:
        if _allowedPatchPath.fullmatch(fact.path) is None:
            raise ValueError("已确认事实仅接受可改写的文本字段；其他事实请先保存到简历")
        if not isinstance(_resolveJsonPointer(resumeJson, fact.path), str):
            raise ValueError("已确认事实必须对应本次简历的文本字段")


def validateBasicComposeOutput(
    output: BasicResumeComposeOutput,
    requestInput: BasicResumeComposeInput,
    *,
    allowSemanticReview: bool = False,
) -> bool:
    reviewRequired = False
    sources = {fragment.fragmentId: fragment.text for fragment in requestInput.sourceFragments}
    knownFragmentIds = set(sources)
    candidateResume = output.candidateResume.model_dump(mode="json")
    if isinstance(output.candidateResume, ComposedResumeDataProjection):
        profile = output.candidateResume.profile
        if any((profile.fullName, profile.phone, profile.email, profile.preciseAddress)) and not (
            requestInput.naturalLanguageInput
        ):
            raise ValueError("仅在确认发送整段自然语言材料时允许从中提取个人信息")
    for sourceReference in output.sourceReferences:
        if not set(sourceReference.fragmentIds) <= knownFragmentIds:
            raise ValueError("候选结果引用了不存在的 fragmentId")
        _resolveJsonPointer(candidateResume, sourceReference.path)
    for path, value in populatedFacts(candidateResume):
        personalField = path.removeprefix("/profile/")
        personalData = requestInput.personalData
        if personalData is not None and personalField in personalData.consentedFields:
            # The form is an explicit source in its own right. Its exact values need
            # not be repeated inside a narrative fragment or invented citation.
            if value != getattr(personalData, personalField):
                raise UnverifiedFactError("事实校验：已授权基础信息不得改写", path=path)
            continue
        references = [
            reference
            for reference in output.sourceReferences
            if path == reference.path or path.startswith(reference.path + "/")
        ]
        if not references:
            raise UnverifiedFactError("候选事实缺少来源覆盖", path=path)
        citedIds = {fragmentId for reference in references for fragmentId in reference.fragmentIds}
        source = "\n".join(sources[fragmentId] for fragmentId in sorted(citedIds))
        try:
            if re.fullmatch(r"/educations/[0-9]+/dateRange/start/year", path):
                start = cast(
                    dict[str, int | None],
                    _resolveJsonPointer(candidateResume, path.rsplit("/", 1)[0]),
                )
                validateEducationStart(source, cast(int, start["year"]), start.get("month"))
            validateLiteralFact(path, value, source)
            if (
                isinstance(value, str)
                and not path.endswith("/proficiency")
                and not isSupportedRewording(source, value)
            ):
                if not allowSemanticReview:
                    raise UnverifiedFactError("事实校验：改写语义需要用户核实")
                reviewRequired = True
        except UnverifiedFactError as factError:
            factError.path = path
            raise
    return reviewRequired


def validateOptimizationOutput(
    output: TargetedResumeOptimizationOutput | ResumeOptimizationConversationOutput,
    resumeProjection: ResumeDataProjection,
    writingContext: WritingContext | None = None,
    *,
    allowSemanticReview: bool = False,
) -> bool:
    reviewRequired = False
    if output.proposedPatch is None:
        if output.nextAction == "reviewPatch":
            raise ValueError("没有 Patch 时不能要求用户审阅 Patch")
        return False
    if output.nextAction != "reviewPatch":
        raise ValueError("存在 Patch 时 nextAction 必须为 reviewPatch")

    resumeJson = resumeProjection.model_dump(mode="json")
    seenPaths: set[str] = set()
    for patchOperation in output.proposedPatch.operations:
        if _allowedPatchPath.fullmatch(patchOperation.path) is None:
            raise ValueError("Provider Patch 路径不在远程改写白名单")
        if patchOperation.path in seenPaths:
            raise ValueError("同一响应不能重复修改同一路径")
        seenPaths.add(patchOperation.path)
        currentValue = _resolveJsonPointer(resumeJson, patchOperation.path)
        if currentValue != patchOperation.oldValue:
            raise ValueError("Provider Patch 的 oldValue 与本次投影不一致")
        confirmedSources = (
            {}
            if writingContext is None
            else {fact.path: fact.text for fact in writingContext.confirmedFacts}
        )
        sourceText = confirmedSources.get(patchOperation.path, patchOperation.oldValue)
        try:
            validateFactText(sourceText, patchOperation.newValue, preserveExisting=True)
            if not isSupportedRewording(sourceText, patchOperation.newValue):
                if not allowSemanticReview:
                    raise UnverifiedFactError("事实校验：改写语义需要用户核实")
                reviewRequired = True
        except UnverifiedFactError as factError:
            factError.path = patchOperation.path
            raise
    return reviewRequired


def permittedPatchPaths(resumeProjection: ResumeDataProjection) -> tuple[str, ...]:
    return tuple(
        path
        for path, value in populatedFacts(resumeProjection.model_dump(mode="json"))
        if isinstance(value, str) and _allowedPatchPath.fullmatch(path)
    )


def _resolveJsonPointer(rootValue: object, pointer: str) -> object:
    currentValue = rootValue
    for encodedSegment in pointer.removeprefix("/").split("/"):
        if re.search(r"~(?![01])", encodedSegment):
            raise ValueError("JSON Pointer 转义无效")
        segment = encodedSegment.replace("~1", "/").replace("~0", "~")
        if isinstance(currentValue, dict):
            currentMapping = cast(dict[str, object], currentValue)
            if segment not in currentMapping:
                raise ValueError("JSON Pointer 指向不存在的字段")
            currentValue = currentMapping[segment]
            continue
        if isinstance(currentValue, list):
            if re.fullmatch(r"0|[1-9][0-9]*", segment) is None:
                raise ValueError("JSON Pointer 数组索引无效")
            index = int(segment)
            if index >= len(currentValue):
                raise ValueError("JSON Pointer 数组索引越界")
            currentValue = currentValue[index]
            continue
        raise ValueError("JSON Pointer 经过非容器字段")
    return currentValue


def hasUsableCandidate(output: RemoteResumeAiOutput) -> bool:
    """Only count output the client can review; clarification is still a paid call."""
    if output.missingInformation:
        return False
    if isinstance(output, BasicResumeComposeOutput):
        for path, value in populatedFacts(output.candidateResume.model_dump(mode="json")):
            if re.fullmatch(r"/(?:skillGroups/[0-9]+/name|customSections/[0-9]+/title)", path):
                continue
            if re.fullmatch(r"/projects/[0-9]+/name", path) and value == "项目经历":
                continue
            return True
        return False
    return output.proposedPatch is not None and output.nextAction == "reviewPatch"
