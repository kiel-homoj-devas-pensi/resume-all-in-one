import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';

import 'support/cloud_options_fixture.dart';

void main() {
  test('云政策使用独立协议且查询不带会话和正文', () async {
    final transport = _ResponseTransport(syntheticCloudOptions());
    final client = _client(transport);
    final options = await client.readCloudOptions();
    expect(options.enabled, isTrue);
    expect(options.policy!.region, 'local-synthetic');
    expect(options.policy!.contentRetentionDays, 7);
    expect(transport.calls, 1);
    expect(transport.method, 'GET');
    expect(transport.uri!.path, '/v1/cloud-resumes/options');
    expect(transport.headers, isEmpty);
    expect(transport.body, isNull);
    client.close();
    expect(transport.closed, isTrue);
  });

  test('未开放响应不得提供可误认为有效的政策', () async {
    final options = await _client(
      _ResponseTransport(syntheticCloudOptions(enabled: false)),
    ).readCloudOptions();
    expect(options.enabled, isFalse);
    expect(options.policy, isNull);
    expect(options.policyFingerprint, isNull);
  });

  final invalid = <String, void Function(Map<String, Object?>)>{
    '协议版本': (v) => v['protocolVersion'] = '0.8.0',
    '生产标志': (v) => v['developmentOnly'] = false,
    '未知字段': (v) => v['privateMarker'] = 'PRIVATE_RESPONSE',
    '扩大范围': (v) => v['scope'] = 'allLocalData',
    '假布尔': (v) => v['enabled'] = 'true',
    '缺政策': (v) => v['policy'] = null,
    '错误指纹': (v) => v['policyFingerprint'] = '0' * 64,
    '页面超限': (v) => v['maximumPageSize'] = 51,
    '游标超期': (v) => v['cursorLifetimeSeconds'] = 901,
    '浮点限制': (v) => v['maximumResponseBytes'] = 65536.0,
    '零请求': (v) => v['maximumRequestBytes'] = 0,
    '大请求': (v) => v['maximumRequestBytes'] = 65537,
    '快照超限': (v) => v['maximumSnapshotBytes'] = 49153,
    '快照超请求': (v) => v['maximumRequestBytes'] = 8192,
    '关闭但留政策': (v) => v['enabled'] = false,
    '非法区域': (v) => (v['policy'] as Map)['region'] = 'PRIVATE_RESPONSE\n',
    '负保留期': (v) => (v['policy'] as Map)['contentRetentionDays'] = -1,
    '政策额外字段': (v) => (v['policy'] as Map)['privateMarker'] = 'PRIVATE_RESPONSE',
  };
  for (final entry in invalid.entries) {
    test('拒绝不一致的云选项：${entry.key}，错误不带响应值', () async {
      final value = syntheticCloudOptions();
      entry.value(value);
      final transport = _ResponseTransport(value);
      await expectLater(
        _client(transport).readCloudOptions(),
        throwsA(
          isA<GatewayApiException>()
              .having((e) => e.code, 'code', 'invalid_gateway_response')
              .having(
                (e) => e.toString().contains('PRIVATE_RESPONSE'),
                'no raw value',
                isFalse,
              ),
        ),
      );
      expect(transport.calls, 1);
    });
  }

  test('超长和无效 UTF-8 云响应都拒绝且不重试', () async {
    for (final bytes in [
      Uint8List(65537),
      Uint8List.fromList([0xff]),
    ]) {
      final transport = _ResponseTransport(syntheticCloudOptions())
        ..rawBytes = bytes;
      await expectLater(
        _client(transport).readCloudOptions(),
        throwsA(isA<GatewayApiException>()),
      );
      expect(transport.calls, 1);
    }
  });

  test('Dart IO 真正发送单次只读请求并保留服务端政策', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    server.listen((request) async {
      calls++;
      expect(request.method, 'GET');
      expect(request.uri.path, '/v1/cloud-resumes/options');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(
        await request.fold<int>(0, (size, bytes) => size + bytes.length),
        0,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(syntheticCloudOptions()));
      await request.response.close();
    });
    final client = GatewayApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      transport: DartIoGatewayHttpTransport(),
      allowInsecureHttp: true,
    );
    addTearDown(client.close);
    expect((await client.readCloudOptions()).policy!.backupRetentionDays, 30);
    expect(calls, 1);
  });

  final nativeUrl = Platform.environment['CLOUD_OPTIONS_TEST_BASE_URL'];
  test('正常 Gateway 工厂真实 TCP 政策可被客户端核验', () async {
    final client = GatewayApiClient(
      baseUri: Uri.parse(nativeUrl!),
      transport: DartIoGatewayHttpTransport(),
      allowInsecureHttp: true,
    );
    addTearDown(client.close);
    final options = await client.readCloudOptions();
    expect(options.enabled, isTrue);
    expect(options.policy!.region, 'local-synthetic');
    expect(options.policyFingerprint, options.policy!.fingerprint);
  }, skip: nativeUrl == null ? '仅在显式本机合成 Gateway 联调时执行' : false);
}

GatewayApiClient _client(GatewayHttpTransport transport) => GatewayApiClient(
  baseUri: Uri.parse('https://gateway.invalid'),
  transport: transport,
);

final class _ResponseTransport implements GatewayHttpTransport {
  _ResponseTransport(this.response);
  final Map<String, Object?> response;
  Uint8List? rawBytes;
  int calls = 0;
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  Map<String, Object?>? body;
  bool closed = false;
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) async {
    calls++;
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    body = jsonBody;
    return GatewayHttpResponse(
      statusCode: 200,
      bodyBytes:
          rawBytes ?? Uint8List.fromList(utf8.encode(jsonEncode(response))),
    );
  }

  @override
  void close() {
    closed = true;
  }
}
