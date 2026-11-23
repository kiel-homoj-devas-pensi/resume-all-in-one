from __future__ import annotations

import asyncio
import json
import logging
import re
from dataclasses import dataclass
from typing import Protocol

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .aigc_metadata import AigcMetadata, extractUpstreamAigc, uniqueJsonObject
from .prompt_registry import ReasoningProfile, promptFor
from .remote_contracts import (
    BasicResumeComposeInput,
    BasicResumeComposeOutput,
    CandidateSourceReference,
    RemoteResumeAiOutput,
    RemoteResumeAiRequest,
    ResumeDataProjection,
    ResumeOptimizationConversationInput,
    ResumeOptimizationConversationOutput,
    TargetedResumeOptimizationInput,
    TargetedResumeOptimizationOutput,
    hasUsableCandidate,
    validateBasicComposeOutput,
    validateOptimizationOutput,
)
from .resume_fact_guard import SEMANTIC_REVIEW_WARNING, UnverifiedFactError, validateLiteralFact
from .usage import ProductCapability
from .volunteer_trial import TrialModelBudget
from .writing_agent import (
    FACT_REVIEW_WARNING,
    prepareWritingTask,
    requireAnswersBeforeCandidate,
    validateWritingScope,
    writingClarification,
    writingFactClarification,
)

GLM_CHAT_COMPLETIONS_ENDPOINT = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
MAXIMUM_PROVIDER_INPUT_BYTES = 49_152
_logger = logging.getLogger("agent_gateway.audit")
_diagnosticFields = frozenset(
    "choices finish_reason message content usage prompt_tokens completion_tokens "
    "outputVersion summary candidateResume schemaVersion profile id headline coarseLocation "
    "fullName phone email preciseAddress workExperiences organization position dateRange "
    "start end year month isCurrent highlights educations institution degree fieldOfStudy "
    "projects name role skillGroups skills certifications issuer issuedOn expiresOn "
    "languages proficiency customSections title items description sourceReferences path "
    "fragmentIds missingInformation question warnings proposedPatch operations type oldValue "
    "newValue reason source category nextAction".split()
)
_diagnosticErrorTypes = frozenset(
    "missing extra_forbidden string_type int_type bool_type tuple_type list_type dict_type "
    "model_type model_attributes_type literal_error too_short too_long value_error "
    "string_too_short string_too_long string_pattern_mismatch greater_than_equal "
    "less_than_equal int_parsing bool_parsing".split()
)
_factReasonCodes = {
    "候选事实缺少来源覆盖": "source_coverage_missing",
    "事实校验：毕业日期不能作为未提供的入学日期": "education_start_unsupported",
    "事实校验：数字或日期与来源不一致": "number_or_date_mismatch",
    "事实校验：新增外文实体或技术名词缺少来源": "entity_unsupported",
    "事实校验：实体或资格原文缺少来源": "entity_unsupported",
    "事实校验：职责程度超出来源": "responsibility_escalation",
    "事实校验：不得删除参与或协助的职责限定": "participation_qualifier_removed",
    "事实校验：语言熟练程度缺少来源": "language_proficiency_unsupported",
    "事实校验：日期缺少来源": "date_unsupported",
    "事实校验：当前任职状态缺少来源": "current_status_unsupported",
    "事实校验：已授权基础信息不得改写": "personal_data_changed",
    "事实校验：改写语义需要用户核实": "semantic_review_required",
}


def _factReasonCode(error: UnverifiedFactError) -> str:
    reason = error.args[0] if error.args else None
    return (
        _factReasonCodes.get(reason, "unverified_fact")
        if isinstance(reason, str)
        else "unverified_fact"
    )


def _diagnosticLocation(location: tuple[str | int, ...]) -> str:
    parts: list[str] = []
    for part in location:
        if part in {"ResumeDataProjection", "ComposedResumeDataProjection"}:
            continue
        if isinstance(part, int) and not isinstance(part, bool) and 0 <= part < 10_000:
            parts.append(str(part))
        elif isinstance(part, str) and part in _diagnosticFields:
            parts.append(part)
        else:
            break
    return "/" + "/".join(parts)


def _factDiagnosticPath(path: str) -> str:
    return _diagnosticLocation(
        tuple(
            int(part) if part.isascii() and part.isdecimal() and len(part) < 5 else part
            for part in path.strip("/").split("/")
        )
    )


def _logProviderDiagnostic(stage: str, error: Exception | None = None) -> None:
    # Never format validation messages, input values, unknown keys, or exception
    # reprs: even an extra field name can contain the user's private material.
    if stage not in {
        "envelope",
        "finish_reason",
        "json",
        "schema",
        "candidate_validation",
        "writing_scope",
    }:
        stage = "candidate_validation"
    location = "/choices/0/finish_reason" if stage == "finish_reason" else "/"
    errorType = "invalid_response"
    if isinstance(error, ValidationError):
        issue = error.errors(include_url=False, include_context=False, include_input=False)[0]
        errorType = issue["type"] if issue["type"] in _diagnosticErrorTypes else "validation_error"
        location = _diagnosticLocation(issue["loc"])
    elif isinstance(error, json.JSONDecodeError):
        errorType = "json_decode_error"
    elif isinstance(error, UnverifiedFactError):
        errorType = _factReasonCode(error)
        location = _factDiagnosticPath(error.path)
    elif isinstance(error, ValueError):
        errorType = "value_error"
        if str(error) in {
            "候选结果引用了不存在的 fragmentId",
            "JSON Pointer 转义无效",
            "JSON Pointer 指向不存在的字段",
            "JSON Pointer 数组索引无效",
            "JSON Pointer 数组索引越界",
            "JSON Pointer 经过非容器字段",
        }:
            stage, errorType, location = (
                "candidate_references",
                "invalid_reference",
                "/sourceReferences",
            )
    _logger.warning(
        "provider_response_rejected stage=%s error_type=%s location=%s",
        stage,
        errorType,
        location,
    )


def _logFactRejection(error: UnverifiedFactError) -> None:
    _logger.warning(
        "resume_fact_rejected path=%s reason=%s",
        _factDiagnosticPath(error.path),
        _factReasonCode(error),
    )


class RemoteProviderUnavailableError(RuntimeError):
    pass


class RemoteProviderRateLimitedError(RuntimeError):
    def __init__(self, retryAfterSeconds: int = 1) -> None:
        super().__init__("remote provider rate limited")
        self.retryAfterSeconds = retryAfterSeconds


class RemoteProviderOutcomeUnknownError(RuntimeError):
    def __init__(self, reason: str = "unspecified") -> None:
        super().__init__("remote_provider_outcome_unknown")
        self.reason = (
            reason
            if reason
            in {
                "read_timeout",
                "write_timeout",
                "protocol_error",
                "network_error",
                "provider_5xx",
            }
            else "unspecified"
        )


class InvalidRemoteProviderResponseError(RuntimeError):
    def __init__(
        self,
        *,
        promptVersion: str | None = None,
        inputTokens: int | None = None,
        outputTokens: int | None = None,
    ) -> None:
        super().__init__("invalid_remote_provider_response")
        self.promptVersion = promptVersion
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens


@dataclass(frozen=True, slots=True)
class RemoteProviderGeneration:
    output: RemoteResumeAiOutput
    promptVersion: str
    inputTokens: int
    outputTokens: int
    usesNetwork: bool
    upstreamAigc: AigcMetadata | None = None


class RemoteResumeProvider(Protocol):
    @property
    def isReady(self) -> bool: ...

    @property
    def usesNetwork(self) -> bool: ...

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration: ...


@dataclass(frozen=True, slots=True)
class GlmProviderConfig:
    apiKey: str
    modelId: str = "glm-5.3"
    requestTimeoutSeconds: float = 120.0
    maximumActiveRequests: int = 2
    maximumQueuedRequests: int = 2
    queueWaitSeconds: float = 1.0

    def __post_init__(self) -> None:
        if len(self.apiKey.strip()) < 16:
            raise ValueError("GLM API Key 未配置或长度异常")
        if not self.modelId.strip():
            raise ValueError("GLM model ID 不能为空")
        if self.requestTimeoutSeconds <= 0:
            raise ValueError("GLM 请求超时必须大于 0")
        if self.maximumActiveRequests <= 0:
            raise ValueError("GLM 活动请求上限必须大于 0")
        if self.maximumQueuedRequests < 0:
            raise ValueError("GLM 等待队列上限不能为负数")
        if self.queueWaitSeconds <= 0:
            raise ValueError("GLM 队列等待时间必须大于 0")


class BoundedProviderGate:
    def __init__(
        self,
        *,
        maximumActiveRequests: int,
        maximumQueuedRequests: int,
        queueWaitSeconds: float,
    ) -> None:
        self._maximumActiveRequests = maximumActiveRequests
        self._maximumQueuedRequests = maximumQueuedRequests
        self._queueWaitSeconds = queueWaitSeconds
        self._activeRequests = 0
        self._waitingRequests = 0
        self._stateChanged = asyncio.Condition()

    async def acquire(self) -> None:
        async with self._stateChanged:
            if self._activeRequests < self._maximumActiveRequests:
                self._activeRequests += 1
                return
            if self._waitingRequests >= self._maximumQueuedRequests:
                raise RemoteProviderRateLimitedError

            self._waitingRequests += 1
            try:
                async with asyncio.timeout(self._queueWaitSeconds):
                    while self._activeRequests >= self._maximumActiveRequests:
                        await self._stateChanged.wait()
                    self._activeRequests += 1
            except TimeoutError as waitError:
                raise RemoteProviderRateLimitedError from waitError
            finally:
                self._waitingRequests -= 1

    async def release(self) -> None:
        async with self._stateChanged:
            if self._activeRequests == 0:
                raise RuntimeError("Provider 活动请求释放次数超过获取次数")
            self._activeRequests -= 1
            self._stateChanged.notify(1)


class _GlmMessage(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    content: str


class _GlmChoice(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    finish_reason: str
    message: _GlmMessage


class _GlmUsage(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    prompt_tokens: int = Field(ge=0)
    completion_tokens: int = Field(ge=0)


class _GlmResponse(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    choices: tuple[_GlmChoice, ...] = Field(min_length=1)
    usage: _GlmUsage


class GlmRemoteResumeProvider:
    def __init__(
        self,
        config: GlmProviderConfig,
        *,
        httpClient: httpx.AsyncClient | None = None,
        trialBudget: TrialModelBudget | None = None,
    ) -> None:
        self._config = config
        self._trialBudget = trialBudget
        self._ownsHttpClient = httpClient is None
        self._httpClient = httpClient or httpx.AsyncClient(
            timeout=httpx.Timeout(config.requestTimeoutSeconds),
            limits=httpx.Limits(
                max_connections=config.maximumActiveRequests,
                max_keepalive_connections=config.maximumActiveRequests,
            ),
        )
        self._executionGate = BoundedProviderGate(
            maximumActiveRequests=config.maximumActiveRequests,
            maximumQueuedRequests=config.maximumQueuedRequests,
            queueWaitSeconds=config.queueWaitSeconds,
        )

    @property
    def isReady(self) -> bool:
        return bool(self._config.apiKey.strip())

    @property
    def usesNetwork(self) -> bool:
        return True

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration:
        capabilityPrompt = promptFor(request.capability)
        writingTask = prepareWritingTask(request)
        clarification = writingClarification(request, writingTask)
        if clarification is not None:
            return RemoteProviderGeneration(
                output=clarification,
                promptVersion=capabilityPrompt.version,
                inputTokens=0,
                outputTokens=0,
                usesNetwork=False,
            )
        serializedProviderInput = json.dumps(
            {
                "promptVersion": capabilityPrompt.version,
                "input": writingTask.providerInput,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if len(serializedProviderInput.encode("utf-8")) > MAXIMUM_PROVIDER_INPUT_BYTES:
            raise ValueError("Provider 字段投影超过 48 KiB")

        if (
            len(capabilityPrompt.systemPrompt.encode("utf-8"))
            + len(serializedProviderInput.encode("utf-8"))
            + 256
            > 65_536
        ):
            raise ValueError("Provider 完整文本超过 64 KiB")

        providerRequest = {
            "model": self._config.modelId,
            "messages": [
                {"role": "system", "content": capabilityPrompt.systemPrompt},
                {"role": "user", "content": serializedProviderInput},
            ],
            "thinking": {"type": "enabled"},
            "reasoning_effort": _reasoningEffort(reasoningProfile),
            "response_format": {"type": "json_object"},
            "max_tokens": capabilityPrompt.maxOutputTokens,
        }

        await self._executionGate.acquire()
        try:
            providerResponse = await self._sendRequest(providerRequest)
        finally:
            await self._executionGate.release()

        try:
            parsedResponse, upstreamAigc = _parseGlmResponse(providerResponse)
            output = _parseCapabilityOutput(
                request,
                parsedResponse.choices[0].message.content,
            )
            output = requireAnswersBeforeCandidate(output, request)
            try:
                validateWritingScope(output, writingTask)
            except ValueError as scopeError:
                _logProviderDiagnostic("writing_scope", scopeError)
                raise InvalidRemoteProviderResponseError from scopeError
        except (InvalidRemoteProviderResponseError, ValueError) as error:
            try:
                actualUsage = _GlmUsage.model_validate(providerResponse.json()["usage"])
            except ValueError, KeyError, TypeError:
                raise InvalidRemoteProviderResponseError from error
            raise InvalidRemoteProviderResponseError(
                promptVersion=capabilityPrompt.version,
                inputTokens=actualUsage.prompt_tokens,
                outputTokens=actualUsage.completion_tokens,
            ) from error
        # Source existence and lexical checks do not prove semantic support. This visible
        # warning remains mandatory even when the model claims its own result is verified.
        output = output.model_copy(
            update={"warnings": (FACT_REVIEW_WARNING, *output.warnings[:19])}
        )
        return RemoteProviderGeneration(
            output=output,
            promptVersion=capabilityPrompt.version,
            inputTokens=parsedResponse.usage.prompt_tokens,
            outputTokens=parsedResponse.usage.completion_tokens,
            usesNetwork=True,
            upstreamAigc=upstreamAigc,
        )

    async def aclose(self) -> None:
        if self._ownsHttpClient:
            await self._httpClient.aclose()

    async def _sendRequest(self, providerRequest: dict[str, object]) -> httpx.Response:
        if self._trialBudget is not None:
            # After local preflight and queue admission, before the only HTTP dispatch.
            # Errors and unknown supplier outcomes keep this conservative slot.
            await asyncio.to_thread(self._trialBudget.reserve)
        try:
            providerResponse = await self._httpClient.post(
                GLM_CHAT_COMPLETIONS_ENDPOINT,
                headers={
                    "Authorization": f"Bearer {self._config.apiKey}",
                    "Content-Type": "application/json",
                },
                json=providerRequest,
            )
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as providerError:
            raise RemoteProviderUnavailableError from providerError
        except (httpx.ReadTimeout, httpx.WriteTimeout, httpx.RemoteProtocolError) as providerError:
            reason = (
                "read_timeout"
                if isinstance(providerError, httpx.ReadTimeout)
                else "write_timeout"
                if isinstance(providerError, httpx.WriteTimeout)
                else "protocol_error"
            )
            raise RemoteProviderOutcomeUnknownError(reason) from providerError
        except httpx.RequestError as providerError:
            raise RemoteProviderOutcomeUnknownError("network_error") from providerError

        if providerResponse.status_code == 429:
            raise RemoteProviderRateLimitedError(_retryAfterSeconds(providerResponse))
        if providerResponse.status_code in {400, 401, 403, 404, 422}:
            raise RemoteProviderUnavailableError
        if providerResponse.status_code >= 500:
            raise RemoteProviderOutcomeUnknownError("provider_5xx")
        if providerResponse.status_code != 200:
            raise RemoteProviderUnavailableError
        return providerResponse


class FakeRemoteResumeProvider:
    @property
    def isReady(self) -> bool:
        return True

    @property
    def usesNetwork(self) -> bool:
        return False

    async def generate(
        self,
        request: RemoteResumeAiRequest,
        *,
        reasoningProfile: ReasoningProfile,
    ) -> RemoteProviderGeneration:
        del reasoningProfile
        capabilityPrompt = promptFor(request.capability)
        if isinstance(request.input, BasicResumeComposeInput):
            firstFragment = request.input.sourceFragments[0]
            candidateResume = ResumeDataProjection.model_validate(
                {
                    "schemaVersion": "0.1.0",
                    "profile": {
                        "id": "candidate-profile",
                        "headline": firstFragment.text[:200],
                        "coarseLocation": "",
                    },
                }
            )
            output: RemoteResumeAiOutput = BasicResumeComposeOutput.model_validate(
                {
                    "outputVersion": "basicResumeCompose.v1",
                    "summary": "Fake Provider 已生成可核对的基础候选",
                    "candidateResume": candidateResume,
                    "sourceReferences": [
                        {
                            "path": "/profile/headline",
                            "fragmentIds": [firstFragment.fragmentId],
                        }
                    ],
                    "warnings": ["仅用于本机契约测试，未访问远程 Provider"],
                }
            )
        elif isinstance(request.input, TargetedResumeOptimizationInput):
            output = TargetedResumeOptimizationOutput(
                outputVersion="targetedResumeOptimization.v1",
                summary="Fake Provider 未发现可安全自动改写的内容",
                warnings=("仅用于本机契约测试，未访问远程 Provider",),
                nextAction="none",
            )
        else:
            output = ResumeOptimizationConversationOutput(
                outputVersion="resumeOptimizationConversation.v1",
                summary="Fake Provider 已读取最近三轮以内的本地上下文",
                warnings=("仅用于本机契约测试，未访问远程 Provider",),
                nextAction="none",
            )
        return RemoteProviderGeneration(
            output=output,
            promptVersion=capabilityPrompt.version,
            inputTokens=0,
            outputTokens=0,
            usesNetwork=False,
        )


def _reasoningEffort(reasoningProfile: ReasoningProfile) -> str:
    return "low" if reasoningProfile is ReasoningProfile.fast else "high"


def _parseGlmResponse(providerResponse: httpx.Response) -> tuple[_GlmResponse, AigcMetadata | None]:
    try:
        raw = json.loads(providerResponse.content, object_pairs_hook=uniqueJsonObject)
        upstreamAigc = extractUpstreamAigc(raw)
        parsedResponse = _GlmResponse.model_validate(raw)
    except (ValueError, ValidationError) as responseError:
        _logProviderDiagnostic("envelope", responseError)
        raise InvalidRemoteProviderResponseError from responseError
    if parsedResponse.choices[0].finish_reason != "stop":
        _logProviderDiagnostic("finish_reason")
        raise InvalidRemoteProviderResponseError
    return parsedResponse, upstreamAigc


def _parseCapabilityOutput(
    request: RemoteResumeAiRequest,
    responseContent: str,
) -> RemoteResumeAiOutput:
    stage = "json"
    try:
        decodedContent = json.loads(responseContent)
        stage = "schema"
        if request.capability is ProductCapability.basicResumeCompose:
            basicComposeOutput = BasicResumeComposeOutput.model_validate(decodedContent)
            if not isinstance(request.input, BasicResumeComposeInput):
                raise InvalidRemoteProviderResponseError
            basicComposeOutput = _normalizeComposeLabels(basicComposeOutput, request.input)
            stage = "candidate_validation"
            requiresReview = validateBasicComposeOutput(
                basicComposeOutput,
                request.input,
                allowSemanticReview=request.input.naturalLanguageInput,
            )
            if not basicComposeOutput.missingInformation and not hasUsableCandidate(
                basicComposeOutput
            ):
                raise InvalidRemoteProviderResponseError
            if requiresReview:
                basicComposeOutput = basicComposeOutput.model_copy(
                    update={
                        "warnings": (SEMANTIC_REVIEW_WARNING, *basicComposeOutput.warnings[:19])
                    }
                )
            return basicComposeOutput
        if request.capability is ProductCapability.targetedResumeOptimization:
            targetedOptimizationOutput = TargetedResumeOptimizationOutput.model_validate(
                decodedContent
            )
            if not isinstance(request.input, TargetedResumeOptimizationInput):
                raise InvalidRemoteProviderResponseError
            stage = "candidate_validation"
            targetedOptimizationOutput, requiresReview = _validatedOptimizationEdits(
                targetedOptimizationOutput,
                request.input,
            )
            if requiresReview:
                targetedOptimizationOutput = targetedOptimizationOutput.model_copy(
                    update={
                        "warnings": (
                            SEMANTIC_REVIEW_WARNING,
                            *targetedOptimizationOutput.warnings[:19],
                        )
                    }
                )
            return targetedOptimizationOutput
        conversationOutput = ResumeOptimizationConversationOutput.model_validate(decodedContent)
        if not isinstance(request.input, ResumeOptimizationConversationInput):
            raise InvalidRemoteProviderResponseError
        stage = "candidate_validation"
        conversationOutput, requiresReview = _validatedOptimizationEdits(
            conversationOutput,
            request.input,
        )
        if requiresReview:
            conversationOutput = conversationOutput.model_copy(
                update={"warnings": (SEMANTIC_REVIEW_WARNING, *conversationOutput.warnings[:19])}
            )
        return conversationOutput
    except UnverifiedFactError as factError:
        # A model answer already consumed one request. Return a question and no patch,
        # preserving actual usage; never spend a second request trying to repair it.
        _logProviderDiagnostic(stage, factError)
        _logFactRejection(factError)
        return writingFactClarification(request, factError.path)
    except (ValueError, ValidationError, InvalidRemoteProviderResponseError) as responseError:
        _logProviderDiagnostic(stage, responseError)
        if isinstance(responseError, InvalidRemoteProviderResponseError):
            raise
        raise InvalidRemoteProviderResponseError from responseError


def _validatedOptimizationEdits[
    OptimizationOutput: (TargetedResumeOptimizationOutput, ResumeOptimizationConversationOutput)
](
    output: OptimizationOutput,
    requestInput: TargetedResumeOptimizationInput | ResumeOptimizationConversationInput,
) -> tuple[OptimizationOutput, bool]:
    """Keep independently valid edits; unsupported edits never reach the client patch.

    Structural errors, duplicate paths, stale values, and unresolved questions still
    reject delivery normally. This neither repairs model text nor starts another call.
    """
    if output.proposedPatch is None or output.nextAction != "reviewPatch":
        return output, validateOptimizationOutput(
            output,
            requestInput.resume,
            requestInput.writingContext,
            allowSemanticReview=requestInput.allowSemanticReview,
        )
    kept = []
    rejected: list[UnverifiedFactError] = []
    seenPaths: set[str] = set()
    requiresReview = False
    for operation in output.proposedPatch.operations:
        if operation.path in seenPaths:
            raise ValueError("同一响应不能重复修改同一路径")
        seenPaths.add(operation.path)
        oneEdit = output.model_copy(
            update={
                "proposedPatch": output.proposedPatch.model_copy(
                    update={"operations": (operation,)}
                )
            }
        )
        try:
            requiresReview |= validateOptimizationOutput(
                oneEdit,
                requestInput.resume,
                requestInput.writingContext,
                allowSemanticReview=requestInput.allowSemanticReview,
            )
        except UnverifiedFactError as error:
            rejected.append(error)
            _logFactRejection(error)
        else:
            kept.append(operation)
    if not kept:
        raise rejected[0]
    if rejected:
        output = output.model_copy(
            update={
                "proposedPatch": output.proposedPatch.model_copy(
                    update={"operations": tuple(kept)}
                ),
                "summary": "已整理可核对的部分修改；未通过事实检查的建议未采用，原文保留。",
                "warnings": (
                    "部分建议未采用，原有内容保留；请审阅其余修改。",
                    *output.warnings[:19],
                ),
            }
        )
    return output, requiresReview


def _optionalComposeInvitation(path: str, question: str) -> bool:
    if re.search(r"冲突|不一致|矛盾|哪个|哪一|还是|核实|确认", question):
        return False
    if re.fullmatch(r"/(?:workExperiences|educations|projects)/[0-9]+/dateRange(?:/.*)?", path):
        # Unknown dates are representable as null. A date invitation must not
        # erase an otherwise useful, fact-validated candidate.
        return bool(re.search(r"时间|日期|年月|起止|开始|结束", question))
    invitation = re.search(
        r"是否愿意|是否方便|选填|可选|如果愿意|如愿意|若方便|如方便|如需|如果需要|若有|如有|可补充|未提供|未填写",
        question,
    )
    optionalProfile = path in {
        "/profile",
        "/profile/fullName",
        "/profile/phone",
        "/profile/email",
        "/profile/preciseAddress",
    }
    if invitation and (optionalProfile or re.fullmatch(r"/educations(?:/.*)?", path)):
        return True
    return bool(
        re.fullmatch(r"/(?:workExperiences|projects)/[0-9]+/highlights(?:/[0-9]+)?", path)
        and re.search(r"量化|覆盖率|百分比|问题数|指标|规模", question)
        and (invitation or re.search(r"是否有", question))
    )


def _normalizeComposeLabels(
    output: BasicResumeComposeOutput, request: BasicResumeComposeInput
) -> BasicResumeComposeOutput:
    """Discard invented roles/names, then validate every remaining fact normally.

    Missing or invalid citations still fail the ordinary validator. Never infer a role
    from a desired job, replace the user's source, or make another provider request.
    """
    if not request.naturalLanguageInput:
        return output
    sources = {fragment.fragmentId: fragment.text for fragment in request.sourceFragments}
    personalData = request.personalData
    if personalData is not None:
        removable = {
            index
            for index, reference in enumerate(output.sourceReferences)
            if reference.path in {f"/profile/{field}" for field in personalData.consentedFields}
            and getattr(output.candidateResume.profile, reference.path.rsplit("/", 1)[-1], None)
            == getattr(personalData, reference.path.rsplit("/", 1)[-1])
            and not set(reference.fragmentIds) <= sources.keys()
        }
        retained = tuple(
            reference
            for index, reference in enumerate(output.sourceReferences)
            if index not in removable
        )
        if removable and any(
            set(reference.fragmentIds) <= sources.keys() for reference in retained
        ):
            output = output.model_copy(update={"sourceReferences": retained})
    canDeliver = hasUsableCandidate(output.model_copy(update={"missingInformation": ()}))
    questions = tuple(
        question
        for question in output.missingInformation
        if not (canDeliver and _optionalComposeInvitation(question.path, question.question))
    )
    if len(questions) != len(output.missingInformation):
        output = output.model_copy(
            update={
                "missingInformation": questions,
                "summary": output.summary if questions else "已整理现有材料，可选资料可稍后补充。",
                "warnings": (
                    "未提供或仅保留本地的选填资料不会阻止生成；请核对已整理内容。",
                    *output.warnings,
                    *(
                        f"可后补：{q.question}"[:200]
                        for q in output.missingInformation
                        if q not in questions
                    ),
                )[:20],
            }
        )
    projects = list(output.candidateResume.projects)
    skillGroups = list(output.candidateResume.skillGroups)
    customSections = list(output.candidateResume.customSections)
    references = list(output.sourceReferences)
    omitted = False

    def normalizeName(
        path: str, value: str, label: str, *, requireLiteralSource: bool = False
    ) -> str:
        nonlocal omitted
        covering = [
            ref for ref in references if path == ref.path or path.startswith(ref.path + "/")
        ]
        needsLayoutReference = not covering
        if not covering:
            parent = path.rsplit("/", 1)[0]
            covering = [
                ref
                for ref in references
                if ref.path == parent
                or ref.path.startswith(parent + "/")
                or parent.startswith(ref.path + "/")
            ]
        citedIds = {fragmentId for ref in covering for fragmentId in ref.fragmentIds}
        if citedIds and not citedIds <= sources.keys():
            return value
        if not citedIds:
            # A fixed column title makes no claim about the user. Its reference only
            # identifies this submitted material; actual skills/content still need
            # their own valid citations and pass the unchanged fact validator.
            references.append(
                CandidateSourceReference(path=path, fragmentIds=(next(iter(sources)),))
            )
            omitted = True
            return label
        source = "\n".join(sources[fragmentId] for fragmentId in sorted(citedIds))
        if value and (not requireLiteralSource or value in source):
            try:
                validateLiteralFact(path, value, source)
                if needsLayoutReference:
                    # Keep an extracted name only after checking it against the
                    # sources already cited for this same project's/group's content.
                    references.append(
                        CandidateSourceReference(
                            path=path, fragmentIds=tuple(sorted(citedIds))[:20]
                        )
                    )
                    omitted = True
                return value
            except UnverifiedFactError:
                pass
        if needsLayoutReference:
            references.append(
                CandidateSourceReference(path=path, fragmentIds=tuple(sorted(citedIds))[:20])
            )
        omitted = True
        return label

    for index, project in enumerate(projects):
        project = project.model_copy(
            update={"name": normalizeName(f"/projects/{index}/name", project.name, "项目经历")}
        )
        projects[index] = project
        if not project.role:
            continue
        path = f"/projects/{index}/role"
        roleReferences = [
            reference
            for reference in output.sourceReferences
            if path == reference.path or path.startswith(reference.path + "/")
        ]
        citedIds = {fragmentId for ref in roleReferences for fragmentId in ref.fragmentIds}
        if not citedIds or not citedIds <= sources.keys():
            continue
        source = "\n".join(sources[fragmentId] for fragmentId in sorted(citedIds))
        try:
            validateLiteralFact(path, project.role, source)
        except UnverifiedFactError:
            projects[index] = project.model_copy(update={"role": ""})
            omitted = True
    for index, group in enumerate(skillGroups):
        skillGroups[index] = group.model_copy(
            update={"name": normalizeName(f"/skillGroups/{index}/name", group.name, "技能")}
        )
    for index, section in enumerate(customSections):
        customSections[index] = section.model_copy(
            update={
                "title": normalizeName(
                    f"/customSections/{index}/title",
                    section.title,
                    "经历与能力",
                    requireLiteralSource=True,
                )
            }
        )
    if not omitted:
        return output
    return BasicResumeComposeOutput.model_validate(
        output.model_copy(
            update={
                "candidateResume": output.candidateResume.model_copy(
                    update={
                        "projects": tuple(projects),
                        "skillGroups": tuple(skillGroups),
                        "customSections": tuple(customSections),
                    }
                ),
                "sourceReferences": tuple(references),
                "warnings": (
                    "未采用无来源的项目、技能或自定义栏目名称；必要标题用中性栏目名，未提供的角色留空。请核对内容。",
                    *output.warnings[:19],
                ),
            }
        ).model_dump(mode="json")
    )


def _retryAfterSeconds(providerResponse: httpx.Response) -> int:
    retryAfterHeader = providerResponse.headers.get("Retry-After")
    if retryAfterHeader is None:
        return 1
    try:
        retryAfterSeconds = int(retryAfterHeader)
    except ValueError:
        return 1
    return max(1, min(retryAfterSeconds, 60))
