import 'gateway_api_client.dart';
import 'legal_consent_controller.dart';

/// One final check for every endpoint, including automatic follow-up reads.
final class LegalGatewayHttpTransport implements GatewayHttpTransport {
  LegalGatewayHttpTransport({
    required GatewayHttpTransport transport,
    required LegalConsentController legalConsent,
  }) : _transport = transport,
       _legalConsent = legalConsent;
  final GatewayHttpTransport _transport;
  final LegalConsentController _legalConsent;

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) {
    if (!_legalConsent.canSendNetworkRequest) {
      throw GatewayApiException(
        code: 'legal_consent_required',
        message: _legalConsent.canUseRemoteServices
            ? '联网已关闭，请先在设置中允许联网。'
            : _legalConsent.blockedReason,
        retryable: false,
      );
    }
    return _transport.sendJson(
      method: method,
      uri: uri,
      headers: headers,
      jsonBody: jsonBody,
    );
  }

  @override
  void close() => _transport.close();
}
