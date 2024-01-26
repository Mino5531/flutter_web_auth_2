import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_web_auth_2_platform_interface/flutter_web_auth_2_platform_interface.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_to_front/window_to_front.dart';

class FlutterWebAuth2DesktopPlugin extends FlutterWebAuth2Platform {
  Webview? webview;
  HttpServer? _server;
  Timer? _authTimeout;

  static void registerWith() {
    FlutterWebAuth2Platform.instance = FlutterWebAuth2DesktopPlugin();
  }

  Future<String> authenticateWebview({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    if (!await WebviewWindow.isWebviewAvailable()) {
      //Microsofts WebView2 must be installed for this to work
      throw StateError('Webview is not available');
    }
    //Reset
    webview?.close();

    final c = Completer<String>();
    debugPrint(
      '''Launching webview with url: $url, callbackUrlScheme: $callbackUrlScheme, tmpDir: ${(await getTemporaryDirectory()).path}''',
    );
    webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowHeight: 720,
        windowWidth: 1280,
        title: 'Authenticate',
        titleBarTopPadding: 0,
        userDataFolderWindows: (await getTemporaryDirectory()).path,
      ),
    );
    webview!.addOnUrlRequestCallback((url) {
      final uri = Uri.parse(url);
      if (uri.scheme == callbackUrlScheme) {
        webview?.close();
        /**
         * Not setting the webview to null will cause a crash if the 
         * application tries to open another webview
         */
        webview = null;
        c.complete(url);
      }
    });
    unawaited(
      /**
       * This is only called when the user closes the window, 
       * not when it is closed programmatically
       */
      webview!.onClose.whenComplete(
        () {
          /**
           * Not setting the webview to null will cause a crash if the 
           * application tries to open another webview
           */
          webview = null;
          c.completeError(
            PlatformException(code: 'CANCELED', message: 'User canceled'),
          );
        },
      ),
    );
    webview!.launch(url);
    return c.future;
  }

  Future<String> authenticateBrowser({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    final parsedOptions = FlutterWebAuth2Options.fromJson(options);

    // Validate callback url
    final callbackUri = Uri.parse(callbackUrlScheme);

    if (callbackUri.scheme != 'http' ||
        (callbackUri.host != 'localhost' && callbackUri.host != '127.0.0.1') ||
        !callbackUri.hasPort) {
      throw ArgumentError(
        'Callback url scheme must start with http://localhost:{port}',
      );
    }

    await _server?.close(force: true);

    _server = await HttpServer.bind('127.0.0.1', callbackUri.port);
    String? result;

    _authTimeout?.cancel();
    _authTimeout = Timer(Duration(seconds: parsedOptions.timeout), () {
      _server?.close();
    });

    await launchUrl(Uri.parse(url));

    await _server!.listen((req) async {
      req.response.headers.add('Content-Type', 'text/html');
      req.response.write(parsedOptions.landingPageHtml);
      await req.response.close();

      result = req.requestedUri.toString();
      await _server?.close();
      _server = null;
    }).asFuture();

    await _server?.close(force: true);
    _authTimeout?.cancel();

    if (result != null) {
      await WindowToFront.activate();
      return result!;
    }
    throw PlatformException(message: 'User canceled login', code: 'CANCELED');
  }

  @override
  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    final parsedOptions = FlutterWebAuth2Options.fromJson(options);
    if (Platform.isLinux) {
      if (parsedOptions.linuxAuthenticationMethod ==
          FlutterWebAuth2DesktopAuthMethod.browser) {
        return authenticateBrowser(
            url: url, callbackUrlScheme: callbackUrlScheme, options: options);
      } else {
        return authenticateWebview(
            url: url, callbackUrlScheme: callbackUrlScheme, options: options);
      }
    } else {
      if (parsedOptions.windowsAuthenticationMethod ==
          FlutterWebAuth2DesktopAuthMethod.browser) {
        return authenticateBrowser(
            url: url, callbackUrlScheme: callbackUrlScheme, options: options);
      } else {
        return authenticateWebview(
            url: url, callbackUrlScheme: callbackUrlScheme, options: options);
      }
    }
  }
}
