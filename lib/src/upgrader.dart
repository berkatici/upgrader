/*
 * Copyright (c) 2018-2022 Larry Aasen. All rights reserved.
 */

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';

import 'appcast.dart';
import 'itunes_search_api.dart';
import 'play_store_search_api.dart';
import 'upgrade_io.dart';
import 'upgrade_messages.dart';

/// Signature of callbacks that have no arguments and return bool.
typedef BoolCallback = bool Function();

/// Signature of callbacks that have a bool argument and no return.
typedef VoidBoolCallback = void Function(bool value);

/// Signature of callback for willDisplayUpgrade. Includes display,
/// minAppVersion, installedVersion, and appStoreVersion.
typedef WillDisplayUpgradeCallback = void Function(
    {required bool display,
    String? minAppVersion,
    String? installedVersion,
    String? appStoreVersion});

/// There are two different dialog styles: Cupertino and Material
enum UpgradeDialogStyle { cupertino, material }

/// A class to define the configuration for the appcast. The configuration
/// contains two parts: a URL to the appcast, and a list of supported OS
/// names, such as "android", "ios".
class AppcastConfiguration {
  final List<String>? supportedOS;
  final String? url;

  AppcastConfiguration({
    this.supportedOS,
    this.url,
  });
}

/// Creates a shared instance of [Upgrader].
Upgrader _sharedInstance = Upgrader();

/// A class to configure the upgrade dialog.
class Upgrader {
  /// Provide an Appcast that can be replaced for mock testing.
  final Appcast? appcast;

  /// The appcast configuration ([AppcastConfiguration]) used by [Appcast].
  /// When an appcast is configured for iOS, the iTunes lookup is not used.
  final AppcastConfiguration? appcastConfig;

  /// Can alert dialog be dismissed on tap outside of the alert dialog. Not used by [UpgradeCard]. (default: false)
  bool canDismissDialog;

  /// Provide an HTTP Client that can be replaced for mock testing.
  final http.Client client;

  /// The country code that will override the system locale. Optional.
  final String? countryCode;

  /// The country code that will override the system locale. Optional. Used only for Android.
  final String? languageCode;

  /// For debugging, always force the upgrade to be available.
  bool debugDisplayAlways;

  /// For debugging, display the upgrade at least once once.
  bool debugDisplayOnce;

  /// Enable print statements for debugging.
  bool debugLogging;

  /// The upgrade dialog style. Used only on UpgradeAlert. (default: material)
  UpgradeDialogStyle dialogStyle;

  /// Duration until alerting user again
  final Duration durationUntilAlertAgain;

  /// The localized messages used for display in upgrader.
  UpgraderMessages messages;

  /// The minimum app version supported by this app. Earlier versions of this app
  /// will be forced to update to the current version. Optional.
  String? minAppVersion;

  /// Called when the ignore button is tapped or otherwise activated.
  /// Return false when the default behavior should not execute.
  BoolCallback? onIgnore;

  /// Called when the later button is tapped or otherwise activated.
  /// Return false when the default behavior should not execute.
  BoolCallback? onLater;

  /// Called when the update button is tapped or otherwise activated.
  /// Return false when the default behavior should not execute.
  BoolCallback? onUpdate;

  /// The [TargetPlatform] that identifies the platform on which the package is
  /// currently executing. Defaults to [defaultTargetPlatform]. Note that
  /// [TargetPlatform] does not include web, but includes mobile and desktop.
  /// This parameter is normally used to change the target platform during testing.
  final TargetPlatform platform;

  /// Called when the user taps outside of the dialog and [canDismissDialog]
  /// is false. Also called when the back button is pressed. Return true for
  /// the screen to be popped. Not used by [UpgradeCard].
  BoolCallback? shouldPopScope;

  /// Hide or show Ignore button on dialog (default: true)
  bool showIgnore;

  /// Hide or show Later button on dialog (default: true)
  bool showLater;

  /// Hide or show release notes (default: true)
  bool showReleaseNotes;

  /// The text style for the cupertino dialog buttons. Used only for
  /// [UpgradeDialogStyle.cupertino]. Optional.
  TextStyle? cupertinoButtonTextStyle;

  /// Called when [Upgrader] determines that an upgrade may or may not be
  /// displayed. The [value] parameter will be true when it should be displayed,
  /// and false when it should not be displayed. One good use for this callback
  /// is logging metrics for your app.
  WillDisplayUpgradeCallback? willDisplayUpgrade;

  /// The target operating system.
  final String _operatingSystem = UpgradeIO.operatingSystem;

  bool _displayed = false;
  bool _initCalled = false;
  PackageInfo? _packageInfo;

  String? _installedVersion;
  String? _appStoreVersion;
  String? _appStoreListingURL;
  String? _releaseNotes;
  String? _updateAvailable;
  DateTime? _lastTimeAlerted;
  String? _lastVersionAlerted;
  String? _userIgnoredVersion;
  bool _hasAlerted = false;
  bool _isCriticalUpdate = false;

  /// Track the initialization future so that [initialize] can be called multiple times.
  Future<bool>? _futureInit;

  final notInitializedExceptionMessage =
      'initialize() not called. Must be called first.';

  Upgrader({
    this.appcastConfig,
    this.appcast,
    UpgraderMessages? messages,
    this.debugDisplayAlways = false,
    this.debugDisplayOnce = false,
    this.debugLogging = false,
    this.durationUntilAlertAgain = const Duration(days: 3),
    this.onIgnore,
    this.onLater,
    this.onUpdate,
    this.shouldPopScope,
    this.willDisplayUpgrade,
    http.Client? client,
    this.showIgnore = true,
    this.showLater = true,
    this.showReleaseNotes = true,
    this.canDismissDialog = false,
    this.countryCode,
    this.languageCode,
    this.minAppVersion,
    this.dialogStyle = UpgradeDialogStyle.material,
    this.cupertinoButtonTextStyle,
    TargetPlatform? platform,
  })  : client = client ?? http.Client(),
        messages = messages ?? UpgraderMessages(),
        platform = platform ?? defaultTargetPlatform {
    if (debugLogging) print("upgrader: instantiated.");
  }

  /// A shared instance of [Upgrader].
  static Upgrader get sharedInstance => _sharedInstance;

  void installPackageInfo({PackageInfo? packageInfo}) {
    _packageInfo = packageInfo;
    _initCalled = false;
  }

  void installAppStoreVersion(String version) {
    _appStoreVersion = version;
  }

  void installAppStoreListingURL(String url) {
    _appStoreListingURL = url;
  }

  /// Initialize [Upgrader] by getting saved preferences, getting platform package info, and getting
  /// released version info.
  Future<bool> initialize() async {
    if (debugLogging) {
      print('upgrader: initialize called');
    }
    if (_futureInit != null) return _futureInit!;

    _futureInit = Future(() async {
      if (debugLogging) {
        print('upgrader: initializing');
      }
      if (_initCalled) {
        assert(false, 'This should never happen.');
        return true;
      }
      _initCalled = true;

      if (messages.languageCode.isEmpty) {
        print('upgrader: error -> languageCode is empty');
      } else if (debugLogging) {
        print('upgrader: languageCode: ${messages.languageCode}');
      }

      await _getSavedPrefs();

      if (debugLogging) {
        print('upgrader: default operatingSystem: '
            '${UpgradeIO.operatingSystem} ${UpgradeIO.operatingSystemVersion}');
        print('upgrader: operatingSystem: $_operatingSystem');
        print('upgrader: platform: $platform');
        print('upgrader: defaultTargetPlatform: $defaultTargetPlatform');
        print('upgrader: '
            'isAndroid: ${UpgradeIO.isAndroid}, '
            'isIOS: ${UpgradeIO.isIOS}, '
            'isLinux: ${UpgradeIO.isLinux}, '
            'isMacOS: ${UpgradeIO.isMacOS}, '
            'isWindows: ${UpgradeIO.isWindows}, '
            'isFuchsia: ${UpgradeIO.isFuchsia}, '
            'isWeb: ${UpgradeIO.isWeb}');
      }

      if (_packageInfo == null) {
        _packageInfo = await PackageInfo.fromPlatform();
        if (debugLogging) {
          print(
              'upgrader: package info packageName: ${_packageInfo!.packageName}');
          print('upgrader: package info appName: ${_packageInfo!.appName}');
          print('upgrader: package info version: ${_packageInfo!.version}');
        }
      }

      _installedVersion = _packageInfo!.version;

      await _updateVersionInfo();

      return true;
    });
    return _futureInit!;
  }

  Future<bool> _updateVersionInfo() async {
    // If there is an appcast for this platform
    if (_isAppcastThisPlatform()) {
      if (debugLogging) {
        print('upgrader: appcast is available for this platform');
      }

      final appcast = this.appcast ?? Appcast(client: client);
      await appcast.parseAppcastItemsFromUri(appcastConfig!.url!);
      if (debugLogging) {
        var count = appcast.items == null ? 0 : appcast.items!.length;
        print('upgrader: appcast item count: $count');
      }
      final criticalUpdateItem = appcast.bestCriticalItem();
      final criticalVersion = criticalUpdateItem?.versionString ?? '';

      final bestItem = appcast.bestItem();
      if (bestItem != null &&
          bestItem.versionString != null &&
          bestItem.versionString!.isNotEmpty) {
        if (debugLogging) {
          print(
              'upgrader: appcast best item version: ${bestItem.versionString}');
          print(
              'upgrader: appcast critical update item version: ${criticalUpdateItem?.versionString}');
        }

        try {
          if (criticalVersion.isNotEmpty &&
              Version.parse(_installedVersion!) <
                  Version.parse(criticalVersion)) {
            _isCriticalUpdate = true;
          }
        } catch (e) {
          print('upgrader: updateVersionInfo could not parse version info $e');
          _isCriticalUpdate = false;
        }

        _appStoreVersion ??= bestItem.versionString;
        _appStoreListingURL ??= bestItem.fileURL;
        _releaseNotes = bestItem.itemDescription;
      }
    } else {
      if (_packageInfo == null || _packageInfo!.packageName.isEmpty) {
        return false;
      }

      // The  country code of the locale, defaulting to `US`.
      final country = countryCode ?? findCountryCode();
      if (debugLogging) {
        print('upgrader: countryCode: $country');
      }

      // The  language code of the locale, defaulting to `en`.
      final language = languageCode ?? findLanguageCode();
      if (debugLogging) {
        print('upgrader: languageCode: $language');
      }

      // Get Android version from Google Play Store, or
      // get iOS version from iTunes Store.
      if (platform == TargetPlatform.android) {
        await _getAndroidStoreVersion(country: country, language: language);
      } else if (platform == TargetPlatform.iOS) {
        final iTunes = ITunesSearchAPI();
        iTunes.debugEnabled = debugLogging;
        iTunes.client = client;
        final response = await (iTunes
            .lookupByBundleId(_packageInfo!.packageName, country: country));

        if (response != null) {
          _appStoreVersion ??= ITunesResults.version(response);
          _appStoreListingURL ??= ITunesResults.trackViewUrl(response);
          _releaseNotes ??= ITunesResults.releaseNotes(response);
          final mav = ITunesResults.minAppVersion(response);
          if (mav != null) {
            minAppVersion = mav.toString();
            if (debugLogging) {
              print('upgrader: ITunesResults.minAppVersion: $minAppVersion');
            }
          }
        }
      }
    }

    return true;
  }

  /// Android info is fetched by parsing the html of the app store page.
  Future<bool?> _getAndroidStoreVersion(
      {String? country, String? language}) async {
    final id = _packageInfo!.packageName;
    final playStore = PlayStoreSearchAPI(client: client);
    playStore.debugEnabled = debugLogging;
    final response =
        await (playStore.lookupById(id, country: country, language: language));
    if (response != null) {
      _appStoreVersion ??= PlayStoreResults.version(response);
      _appStoreListingURL ??=
          playStore.lookupURLById(id, language: language, country: country);
      _releaseNotes ??= PlayStoreResults.releaseNotes(response);
      final mav = PlayStoreResults.minAppVersion(response);
      if (mav != null) {
        minAppVersion = mav.toString();
        if (debugLogging) {
          print('upgrader: PlayStoreResults.minAppVersion: $minAppVersion');
        }
      }
    }

    return true;
  }

  bool _isAppcastThisPlatform() {
    if (appcastConfig == null ||
        appcastConfig!.url == null ||
        appcastConfig!.url!.isEmpty) {
      return false;
    }

    // Since this appcast config contains a URL, this appcast is valid.
    // However, if the supported OS is not listed, it is not supported.
    // When there are no supported OSes listed, they are all supported.
    var supported = true;
    if (appcastConfig!.supportedOS != null) {
      supported = appcastConfig!.supportedOS!.contains(_operatingSystem);
    }
    return supported;
  }

  bool _verifyInit() {
    if (!_initCalled) {
      throw (notInitializedExceptionMessage);
    }
    return true;
  }

  String appName() {
    _verifyInit();
    return _packageInfo?.appName ?? '';
  }

  String? currentAppStoreListingURL() => _appStoreListingURL;

  String? currentAppStoreVersion() => _appStoreVersion;

  String? currentInstalledVersion() => _installedVersion;

  String? get releaseNotes => _releaseNotes;

  String message() {
    var msg = messages.message(UpgraderMessage.body)!;
    msg = msg.replaceAll('{{appName}}', appName());
    msg = msg.replaceAll(
        '{{currentAppStoreVersion}}', currentAppStoreVersion() ?? '');
    msg = msg.replaceAll(
        '{{currentInstalledVersion}}', currentInstalledVersion() ?? '');
    return msg;
  }

  /// Only called by [UpgradeAlert].
  void checkVersion({required BuildContext context}) {
    if (!_displayed) {
      final shouldDisplay = shouldDisplayUpgrade();
      if (debugLogging) {
        print(
            'upgrader: shouldDisplayReleaseNotes: ${shouldDisplayReleaseNotes()}');
      }
      if (shouldDisplay) {
        _displayed = true;
        Future.delayed(const Duration(milliseconds: 0), () {
          _showDialog(
              context: context,
              title: messages.message(UpgraderMessage.title),
              message: message(),
              releaseNotes: shouldDisplayReleaseNotes() ? _releaseNotes : null,
              canDismissDialog: canDismissDialog);
        });
      }
    }
  }

  bool blocked() {
    return belowMinAppVersion() || _isCriticalUpdate;
  }

  bool shouldDisplayUpgrade() {
    final isBlocked = blocked();

    if (debugLogging) {
      print('upgrader: blocked: $isBlocked');
      print('upgrader: debugDisplayAlways: $debugDisplayAlways');
      print('upgrader: debugDisplayOnce: $debugDisplayOnce');
      print('upgrader: hasAlerted: $_hasAlerted');
    }

    // If installed version is below minimum app version, or is a critical update,
    // disable ignore and later buttons.
    if (isBlocked) {
      showIgnore = false;
      showLater = false;
    }
    bool rv = true;
    if (debugDisplayAlways || (debugDisplayOnce && !_hasAlerted)) {
      rv = true;
    } else if (!isUpdateAvailable()) {
      rv = false;
    } else if (isBlocked) {
      rv = true;
    } else if (isTooSoon() || alreadyIgnoredThisVersion()) {
      rv = false;
    }
    if (debugLogging) {
      print('upgrader: shouldDisplayUpgrade: $rv');
    }

    // Call the [willDisplayUpgrade] callback when available.
    if (willDisplayUpgrade != null) {
      willDisplayUpgrade!(
          display: rv,
          minAppVersion: minAppVersion,
          installedVersion: _installedVersion,
          appStoreVersion: _appStoreVersion);
    }

    return rv;
  }

  /// Is installed version below minimum app version?
  bool belowMinAppVersion() {
    var rv = false;
    if (minAppVersion != null) {
      try {
        final minVersion = Version.parse(minAppVersion!);
        final installedVersion = Version.parse(_installedVersion!);
        rv = installedVersion < minVersion;
      } catch (e) {
        print(e);
      }
    }
    return rv;
  }

  bool isTooSoon() {
    if (_lastTimeAlerted == null) {
      return false;
    }

    final lastAlertedDuration = DateTime.now().difference(_lastTimeAlerted!);
    final rv = lastAlertedDuration < durationUntilAlertAgain;
    if (rv && debugLogging) {
      print('upgrader: isTooSoon: true');
    }
    return rv;
  }

  bool alreadyIgnoredThisVersion() {
    final rv =
        _userIgnoredVersion != null && _userIgnoredVersion == _appStoreVersion;
    if (rv && debugLogging) {
      print('upgrader: alreadyIgnoredThisVersion: true');
    }
    return rv;
  }

  bool isUpdateAvailable() {
    if (debugLogging) {
      print('upgrader: appStoreVersion: $_appStoreVersion');
      print('upgrader: installedVersion: $_installedVersion');
      print('upgrader: minAppVersion: $minAppVersion');
    }
    if (_appStoreVersion == null || _installedVersion == null) {
      if (debugLogging) print('upgrader: isUpdateAvailable: false');
      return false;
    }

    if (_updateAvailable == null) {
      try {
        final appStoreVersion = Version.parse(_appStoreVersion!);
        final installedVersion = Version.parse(_installedVersion!);

        final available = appStoreVersion > installedVersion;
        _updateAvailable = available ? _appStoreVersion : null;
      } on Exception catch (e) {
        print('upgrader: isUpdateAvailable: $e');
      }
    }
    final isAvailable = _updateAvailable != null;
    if (debugLogging) print('upgrader: isUpdateAvailable: $isAvailable');
    return isAvailable;
  }

  bool shouldDisplayReleaseNotes() {
    return showReleaseNotes && (_releaseNotes?.isNotEmpty ?? false);
  }

  /// Determine the current country code, either from the context, or
  /// from the system-reported default locale of the device. The default
  /// is `US`.
  String? findCountryCode({BuildContext? context}) {
    Locale? locale;
    if (context != null) {
      locale = Localizations.maybeLocaleOf(context);
    } else {
      // Get the system locale
      locale = PlatformDispatcher.instance.locale;
    }
    final code = locale == null || locale.countryCode == null
        ? 'US'
        : locale.countryCode;
    return code;
  }

  /// Determine the current language code, either from the context, or
  /// from the system-reported default locale of the device. The default
  /// is `en`.
  String? findLanguageCode({BuildContext? context}) {
    Locale? locale;
    if (context != null) {
      locale = Localizations.maybeLocaleOf(context);
    } else {
      // Get the system locale
      locale = PlatformDispatcher.instance.locale;
    }
    final code = locale == null ? 'en' : locale.languageCode;
    return code;
  }

  void _showDialog(
      {required BuildContext context,
      required String? title,
      required String message,
      required String? releaseNotes,
      required bool canDismissDialog}) {
    if (debugLogging) {
      print('upgrader: showDialog title: $title');
      print('upgrader: showDialog message: $message');
      print('upgrader: showDialog releaseNotes: $releaseNotes');
    }

    // Save the date/time as the last time alerted.
    saveLastAlerted();

    showDialog(
      barrierDismissible: canDismissDialog,
      context: context,
      builder: (BuildContext context) {
        return WillPopScope(
          onWillPop: () async => _shouldPopScope(),
          child: dialogStyle == UpgradeDialogStyle.material
              ? _alertDialog(title ?? '', message, releaseNotes, context)
              : _cupertinoAlertDialog(
                  title ?? '', message, releaseNotes, context),
        );
      },
    );
  }

  /// Called when the user taps outside of the dialog and [canDismissDialog]
  /// is false. Also called when the back button is pressed. Return true for
  /// the screen to be popped. Defaults to false.
  bool _shouldPopScope() {
    if (debugLogging) {
      print('upgrader: onWillPop called');
    }
    if (shouldPopScope != null) {
      final should = shouldPopScope!();
      if (debugLogging) {
        print('upgrader: shouldPopScope=$should');
      }
      return should;
    }

    return false;
  }

  AlertDialog _alertDialog(String title, String message, String? releaseNotes,
      BuildContext context) {
    Widget? notes;
    if (releaseNotes != null) {
      notes = Padding(
          padding: const EdgeInsets.only(top: 15.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(messages.message(UpgraderMessage.releaseNotes) ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(releaseNotes),
            ],
          ));
    }
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
      ),
      elevation: 20,
      titlePadding: EdgeInsets.zero,
      title: Column(
        children: [
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
                color: Color(0xFF092E42),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12.0),
                  topRight: Radius.circular(12.0),
                )),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20.0),
              child: Image.asset(
                'assets/dinamik-logo.png',
                width: 100,
                height: 100,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(title, key: const Key('upgrader.dialog.title')),
        ],
      ),
      content: Container(
        constraints: const BoxConstraints(maxHeight: 400),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(message),
              Padding(
                padding: const EdgeInsets.only(top: 15.0),
                child: Text(messages.message(UpgraderMessage.prompt) ?? ''),
              ),
              if (notes != null) notes,
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (showIgnore)
          TextButton(
              child: Text(
                  messages.message(UpgraderMessage.buttonTitleIgnore) ?? ''),
              onPressed: () => onUserIgnored(context, true)),
        if (showLater)
          TextButton(
              child: Text(
                  messages.message(UpgraderMessage.buttonTitleLater) ?? ''),
              onPressed: () => onUserLater(context, true)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 20),
          child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6.0),
                ),
              ),
              child: Text(
                  messages.message(UpgraderMessage.buttonTitleUpdate) ?? ''),
              onPressed: () => onUserUpdated(context, !blocked())),
        ),
      ],
    );
  }

  CupertinoAlertDialog _cupertinoAlertDialog(String title, String message,
      String? releaseNotes, BuildContext context) {
    Widget? notes;
    if (releaseNotes != null) {
      notes = Padding(
          padding: const EdgeInsets.only(top: 15.0),
          child: Column(
            children: <Widget>[
              Text(messages.message(UpgraderMessage.releaseNotes) ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(
                releaseNotes,
                maxLines: 14,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ));
    }
    return CupertinoAlertDialog(
      title: Text(title),
      content: Column(
        // mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          Text(message),
          Padding(
              padding: const EdgeInsets.only(top: 15.0),
              child: Text(messages.message(UpgraderMessage.prompt) ?? '')),
          if (notes != null) notes,
        ],
      ),
      actions: <Widget>[
        if (showIgnore)
          CupertinoDialogAction(
              textStyle: cupertinoButtonTextStyle,
              child: Text(
                  messages.message(UpgraderMessage.buttonTitleIgnore) ?? ''),
              onPressed: () => onUserIgnored(context, true)),
        if (showLater)
          CupertinoDialogAction(
              textStyle: cupertinoButtonTextStyle,
              child: Text(
                  messages.message(UpgraderMessage.buttonTitleLater) ?? ''),
              onPressed: () => onUserLater(context, true)),
        CupertinoDialogAction(
            textStyle: cupertinoButtonTextStyle,
            isDefaultAction: true,
            child:
                Text(messages.message(UpgraderMessage.buttonTitleUpdate) ?? ''),
            onPressed: () => onUserUpdated(context, !blocked())),
      ],
    );
  }

  void onUserIgnored(BuildContext context, bool shouldPop) {
    if (debugLogging) {
      print('upgrader: button tapped: ignore');
    }

    // If this callback has been provided, call it.
    var doProcess = true;
    if (onIgnore != null) {
      doProcess = onIgnore!();
    }

    if (doProcess) {
      _saveIgnored();
    }

    if (shouldPop) {
      popNavigator(context);
    }
  }

  void onUserLater(BuildContext context, bool shouldPop) {
    if (debugLogging) {
      print('upgrader: button tapped: later');
    }

    // If this callback has been provided, call it.
    var doProcess = true;
    if (onLater != null) {
      doProcess = onLater!();
    }

    if (doProcess) {}

    if (shouldPop) {
      popNavigator(context);
    }
  }

  void onUserUpdated(BuildContext context, bool shouldPop) {
    if (debugLogging) {
      print('upgrader: button tapped: update now');
    }

    // If this callback has been provided, call it.
    var doProcess = true;
    if (onUpdate != null) {
      doProcess = onUpdate!();
    }

    if (doProcess) {
      _sendUserToAppStore();
    }

    if (shouldPop) {
      popNavigator(context);
    }
  }

  static Future<void> clearSavedSettings() async {
    var prefs = await SharedPreferences.getInstance();
    await prefs.remove('userIgnoredVersion');
    await prefs.remove('lastTimeAlerted');
    await prefs.remove('lastVersionAlerted');

    return;
  }

  void popNavigator(BuildContext context) {
    Navigator.of(context).pop();
    _displayed = false;
  }

  Future<bool> _saveIgnored() async {
    var prefs = await SharedPreferences.getInstance();

    _userIgnoredVersion = _appStoreVersion;
    await prefs.setString('userIgnoredVersion', _userIgnoredVersion ?? '');
    return true;
  }

  Future<bool> saveLastAlerted() async {
    var prefs = await SharedPreferences.getInstance();
    _lastTimeAlerted = DateTime.now();
    await prefs.setString('lastTimeAlerted', _lastTimeAlerted.toString());

    _lastVersionAlerted = _appStoreVersion;
    await prefs.setString('lastVersionAlerted', _lastVersionAlerted ?? '');

    _hasAlerted = true;
    return true;
  }

  Future<bool> _getSavedPrefs() async {
    var prefs = await SharedPreferences.getInstance();
    final lastTimeAlerted = prefs.getString('lastTimeAlerted');
    if (lastTimeAlerted != null) {
      _lastTimeAlerted = DateTime.parse(lastTimeAlerted);
    }

    _lastVersionAlerted = prefs.getString('lastVersionAlerted');

    _userIgnoredVersion = prefs.getString('userIgnoredVersion');

    return true;
  }

  void _sendUserToAppStore() async {
    if (_appStoreListingURL == null || _appStoreListingURL!.isEmpty) {
      if (debugLogging) {
        print('upgrader: empty _appStoreListingURL');
      }
      return;
    }

    if (debugLogging) {
      print('upgrader: launching: $_appStoreListingURL');
    }

    if (await canLaunchUrl(Uri.parse(_appStoreListingURL!))) {
      try {
        await launchUrl(Uri.parse(_appStoreListingURL!),
            mode: UpgradeIO.isAndroid
                ? LaunchMode.externalNonBrowserApplication
                : LaunchMode.platformDefault);
      } catch (e) {
        if (debugLogging) {
          print('upgrader: launch to app store failed: $e');
        }
      }
    } else {}
  }
}
