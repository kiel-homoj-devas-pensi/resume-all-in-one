import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_domain/resume_domain.dart';

ResumeAigcMetadata _label(String id) =>
    ResumeAigcMetadata.firstGeneration(providerName: 'Ji Ouqi', contentId: id);

String _encode(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

Map<String, Object?> _body({
  String id = 'usage-synthetic',
  bool network = true,
}) => {
  'protocolVersion': gatewayRemoteProtocolVersion,
  'operationId': id,
  'clientRequestId': 'synthetic-action',
  'capability': 'basicResumeCompose',
  'status': 'succeeded',
  'output': <String, Object?>{},
  'execution': {'usesNetwork': network, 'promptVersion': 'synthetic.v1'},
};

GatewayHttpResponse _response({
  List<String> versions = const ['1'],
  List<String>? labels,
  Map<String, Object?>? body,
}) => GatewayHttpResponse(
  statusCode: 200,
  bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body ?? _body()))),
  aigcMetadataHeaders:
      labels ?? [_encode(_label('usage-synthetic').toJsonString())],
  aigcVersionHeaders: versions,
);

Future<GatewayRemoteAiResponse> _generate(GatewayApiClient api) =>
    api.submitRemoteAiRequest(
      sessionToken: 'synthetic-session',
      clientRequestId: 'synthetic-action',
      idempotencyKey: 'synthetic-idempotency',
      capability: RemoteAiCapability.basicResumeCompose,
      input: const {},
    );

void main() {
  test(
    'Python producer vectors decode identically through the actual Dart client',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  '../../services/agent_gateway/tests/fixtures/aigc-header-v1.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(fixture['transportVersion'], '1');
      final vectors = fixture['vectors'] as List;
      expect(vectors, hasLength(2));
      final legal =
          jsonDecode(
                await File('assets/legal/legal_bundle.json').readAsString(),
              )
              as Map<String, dynamic>;
      final publicProviderName = (legal['operator'] as Map)['aiMetadataName'];
      expect(publicProviderName, 'Ji Ouqi');
      for (final vector in vectors.cast<Map<String, dynamic>>()) {
        final api = GatewayApiClient(
          baseUri: Uri.parse('https://gateway.example'),
          transport: _Transport([
            _response(
              labels: [vector['expectedHeader'] as String],
              body: _body(id: vector['operationId'] as String),
            ),
          ]),
        );
        final received = (await _generate(api)).aigcMetadata!;
        expect(received.toJson(), vector['expectedMetadata']);
        expect(received.toJsonString(), vector['expectedInnerJson']);
        expect(received.contentPropagator, publicProviderName);
        api.close();
      }
    },
  );

  test(
    'known header preserves literal provider space; legacy gateway stays unknown',
    () async {
      final api = GatewayApiClient(
        baseUri: Uri.parse('https://gateway.example'),
        transport: _Transport([
          _response(),
          _response(versions: [], labels: []),
        ]),
      );
      expect((await _generate(api)).aigcMetadata!.contentProducer, 'Ji Ouqi');
      expect((await _generate(api)).aigcMetadata, isNull);
      api.close();
    },
  );

  final malformed = <String, GatewayHttpResponse>{
    'missing version': _response(versions: []),
    'missing label': _response(labels: []),
    'unknown version': _response(versions: ['2']),
    'duplicate version': _response(versions: ['1', '1']),
    'duplicate label': _response(labels: ['a', 'a']),
    'invalid base64': _response(labels: ['*']),
    'padded base64': _response(labels: ['e30=']),
    'invalid UTF8': _response(labels: ['_w']),
    'oversized header': _response(labels: ['a' * 5463]),
    'wrong metadata fields': _response(labels: [_encode('{"Label":"1"}')]),
    'duplicate JSON keys': _response(
      labels: [
        _encode(
          _label(
            'usage-synthetic',
          ).toJsonString().replaceFirst('{', '{"Label":"1",'),
        ),
      ],
    ),
    'wrong original operation': _response(
      labels: [_encode(_label('another-operation').toJsonString())],
    ),
    'label on local provider': _response(body: _body(network: false)),
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key} without silently dropping metadata', () async {
      final api = GatewayApiClient(
        baseUri: Uri.parse('https://gateway.example'),
        transport: _Transport([entry.value]),
      );
      await expectLater(_generate(api), throwsA(isA<GatewayApiException>()));
      api.close();
    });
  }

  test(
    'original-result recovery retains header and never starts a model POST',
    () async {
      final transport = _Transport([_response()]);
      final api = GatewayApiClient(
        baseUri: Uri.parse('https://gateway.example'),
        transport: transport,
        originalResultRecoveryEnabled: true,
      );
      final result = await api.recoverOriginalResult(
        sessionToken: 'synthetic-session',
        clientRequestId: 'synthetic-action',
        capability: RemoteAiCapability.basicResumeCompose,
        idempotencyKey: 'synthetic-idempotency',
      );
      expect(result.aigcMetadata!.toJson(), _label('usage-synthetic').toJson());
      expect(transport.paths, ['/v1/resume-ai/results/lookup']);
      api.close();
    },
  );

  test(
    'real Dart IO transport exposes metadata header as a single bounded value',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handled = server.first.then((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Resume-AIGC-Version', '1');
        request.response.headers.set(
          'X-Resume-AIGC',
          _encode(_label('usage-synthetic').toJsonString()),
        );
        request.response.write(jsonEncode(_body()));
        await request.response.close();
      });
      final api = GatewayApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        allowInsecureHttp: true,
        transport: DartIoGatewayHttpTransport(),
      );
      try {
        expect((await _generate(api)).aigcMetadata!.contentProducer, 'Ji Ouqi');
        await handled;
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );
}

final class _Transport implements GatewayHttpTransport {
  _Transport(this.responses);
  final List<GatewayHttpResponse> responses;
  final List<String> paths = [];

  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    paths.add(uri.path);
    return responses.removeAt(0);
  }

  @override
  void close() {}
}
