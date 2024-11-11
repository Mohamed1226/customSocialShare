import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:custom_social_share/custom_social_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

class CustomSocial {
  static const MethodChannel _channel = MethodChannel('snapkit');

  /// platformVersion returns a `String` of the current platform
  /// the appplication is running on, it usally includes both the
  /// Operating System name eg (iOS / Android) and the Version
  /// Number eg (15 / 12)
  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  late StreamController<SnapchatUser?> _authStatusController;
  late Stream<SnapchatUser?> onAuthStateChanged;

  SnapchatAuthStateListener? _authStateListener;

  /// Creates a new `Snapkit` instance
  CustomSocial() {
    _authStatusController = StreamController<SnapchatUser?>();
    onAuthStateChanged = _authStatusController.stream;
    _authStatusController.add(null);

    currentUser.then((user) {
      _authStatusController.add(user);
      _authStateListener?.onLogin(user);
    }).catchError((error, StackTrace stacktrace) {
      _authStatusController.add(null);
      _authStateListener?.onLogout();
    });
  }

  /// Add a class that implements the `SnapchatAuthStateListener` class as
  /// a listener
  void addAuthStateListener(SnapchatAuthStateListener authStateListener) {
    _authStateListener = authStateListener;
  }

  /// login opens Snapchat's OAuth screen in-app or through a browser if
  /// Snapchat is not installed. It will then return the logged in `SnapchatUser`
  /// An error will be thrown if something goes wrong
  Future<SnapchatUser> login() async {
    await _channel.invokeMethod('callLogin');
    final currentUser = await this.currentUser;
    _authStatusController.add(currentUser);
    _authStateListener?.onLogin(currentUser);
    return currentUser;
  }

  /// verifyPhoneNumber verifies if the [phoneNumber] passed
  /// matches the phone number of the currently signed in
  /// user in the snapchat app. Always returns `false` on
  /// Android. A two character [region] code and [phoneNumber]
  /// must be passed
  ///
  /// [region] is a two (2) character region code eg. 'US'
  ///
  /// [phoneNumber] is a ten (10) character `String` containing an area code and phone number
  ///
  /// Throws a `PlatformException` if the phone number is incorrectly
  /// formatted, if the user cancelled the action or if something else went wrong
  Future<bool> verifyPhoneNumber(String region, String phoneNumber) async {
    try {
      List<dynamic> resVerify =
          await _channel.invokeMethod('verifyNumber', <String, String>{
        'phoneNumber': phoneNumber,
        'region': region.toString(),
      }) as List<dynamic>;

      String phoneId = resVerify[0];
      String verifyId = resVerify[1];

      http.Response res = await http.post(
        Uri(
          scheme: 'https',
          host: 'api.snapkit.com',
          path: '/v1/phoneverify/verify_result',
        ),
        body: {
          'phone_number_id': phoneId,
          'phone_number_verify_id': verifyId,
          'phone_number': phoneNumber,
          'region': region.toString(),
        },
      );

      if (res.statusCode == 200) {
        dynamic json = jsonDecode(res.body);
        return (json['verified'] as bool?) ?? false;
      } else {
        return false;
      }
    } on PlatformException catch (e) {
      throw e;
    }
  }

  /// logout clears your apps local session and refresh tokens. You will
  /// no longer be able to make requests to fetch the `SnapchatUser` with
  /// [currentUser].
  ///
  /// Call [closeStream] to close the stream and prevent a
  /// resource sink.
  Future<void> logout() async {
    await _channel.invokeMethod('callLogout');
    _authStatusController.add(null);
    _authStateListener?.onLogout();
  }

  /// Closes the `AuthState` Stream
  void closeStream() {
    _authStatusController.close();
  }

  /// currentUser fetches an up to date `SnapchatUser` and returns it.
  ///
  /// Throws a `PlatformException` if the user wasn't previously logged in
  Future<SnapchatUser> get currentUser async {
    try {
      final List<dynamic> userDetails =
          (await _channel.invokeMethod('getUser')) as List<dynamic>;
      dynamic details2 = userDetails[2];
      String? bitmojiUrl;
      if (details2.runtimeType == Null || details2 == null) {
        bitmojiUrl = null;
      } else {
        bitmojiUrl = details2 as String;
      }
      return SnapchatUser(
          userDetails[0] as String, userDetails[1] as String, bitmojiUrl);
    } on PlatformException catch (e) {
      throw e;
    }
  }

  /// share shares Media to be sent in the Snapchat app. [mediaType]
  /// defines what type of background media is to be shared.
  ///
  /// `SnapchatMediaType.PHOTO` requires [image] to be non `null`.
  ///
  /// `SnapchatMediaType.VIDEO` requires [videoUrl] to be non `null`.
  ///
  /// [image] is an `ImageProvider` instance
  ///
  /// [videoUrl] is a `String` that contains an external url eg. https://domain.com/video.mp4/
  ///
  /// [SnapchatSticker] is a `SnapchatSticker` instance
  ///
  /// [caption] is a `String` no longer than 250 characters
  ///
  /// [attachmentUrl] is a `String` that contains an external url eg. https://domain.com/
  Future<void> share(
    SnapchatMediaType mediaType, {
    ImageProvider<Object>? image,
    String? videoPath,
    SnapchatSticker? sticker,
    String? caption,
    String? attachmentUrl,
  }) async {
    assert(caption != null ? caption.length <= 250 : true);

    Completer<File?> imageCompleter = Completer<File?>();
    Completer<File?> videoCompleter = Completer<File?>();

    if (mediaType == SnapchatMediaType.PHOTO) {
      assert(image != null);
      image!
          .resolve(ImageConfiguration())
          .addListener(ImageStreamListener((imageInfo, _) async {
        String path = (await getTemporaryDirectory()).path;
        ByteData? byteData =
            await imageInfo.image.toByteData(format: ImageByteFormat.png);
        ByteBuffer buffer = byteData!.buffer;

        File file = await File('$path/image.png').writeAsBytes(
            buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));

        imageCompleter.complete(file);
      }));
    } else {
      imageCompleter.complete(null);
    }

    if (mediaType == SnapchatMediaType.VIDEO) {
      assert(videoPath != null);
      String path = (await getTemporaryDirectory()).path;
      ByteData byteData = await rootBundle.load(videoPath!);
      ByteBuffer buffer = byteData.buffer;

      File file = await File('$path/video.mp4').writeAsBytes(
          buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));

      videoCompleter.complete(file);
    } else {
      videoCompleter.complete(null);
    }

    File? imageFile = await imageCompleter.future;
    File? videoFile = await videoCompleter.future;

    await _channel.invokeMethod('sendMedia', <String, dynamic>{
      'mediaType':
          mediaType.toString().substring(mediaType.toString().indexOf('.') + 1),
      'imagePath': imageFile?.path,
      'videoPath': videoFile?.path,
      'sticker': sticker != null ? await sticker.toMap() : null,
      'caption': caption,
      'attachmentUrl': attachmentUrl
    });
  }

  /// isSnapchatInstalled returns a `bool` of whether or not the Snapchat app
  /// is installed on the user's phone.
  Future<bool> get isSnapchatInstalled async {
    bool isInstalled;
    isInstalled = await _channel.invokeMethod('isInstalled');
    return isInstalled;
  }

  /// snapchatButton returns a `SnapchatButton` Widget that is already setup
  /// and will start the login flow when pressed
  SnapchatButton get snapchatButton {
    return SnapchatButton(snapkit: this);
  }
}

class SnapchatUser {
  /// A Snapchat user's Unique ID
  final String externalId;

  /// A Snapchat user's Display Name (Not their username), can be changed by the user through Snapchat
  final String displayName;

  /// An automatic updating static URL to a Snapchat user's Bitmoji
  final String? bitmojiUrl;

  /// Creates a new `SnapchatUser`
  SnapchatUser(this.externalId, this.displayName, this.bitmojiUrl);
}

class SnapchatSticker {
  /// Url to the Image to be used as a Sticker
  ImageProvider<Object> image;

  /// Size of the Sticker relative to the screen
  Size size;

  /// Offset of the Sticker from the top left of the screen
  StickerOffset offset;

  /// Rotation of the Sticker in degrees Clockwise
  StickerRotation rotation;

  /// Creates a new `SnapchatSticker`
  SnapchatSticker({
    required this.image,
    required this.size,
    this.offset = const StickerOffset(0.5, 0.5),
    this.rotation = const StickerRotation(0),
  });

  Future<Map<String, dynamic>> toMap() async {
    Completer<Map<String, dynamic>> c = Completer<Map<String, dynamic>>();

    image
        .resolve(ImageConfiguration())
        .addListener(ImageStreamListener((imageInfo, _) async {
      String path = (await getTemporaryDirectory()).path;
      ByteData? byteData =
          await imageInfo.image.toByteData(format: ImageByteFormat.png);
      ByteBuffer buffer = byteData!.buffer;
      File file = await File('$path/sticker.png').writeAsBytes(
          buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));

      c.complete(<String, dynamic>{
        'imagePath': file.path,
        'width': size.width,
        'height': size.height,
        'offsetX': offset.horizontal,
        'offsetY': offset.vertical,
        'rotation': rotation.rotation,
      });
    }));

    return c.future;
  }
}

class StickerOffset {
  /// Value between 0.0 and 1.0
  ///
  /// Offset from the left of the screen
  final double horizontal;

  /// Value between 0.0 and 1.0
  ///
  /// Offset from the top of the screen
  final double vertical;

  const StickerOffset(this.horizontal, this.vertical)
      : assert((horizontal >= 0 && horizontal <= 1) &&
            (vertical >= 0 && vertical <= 1));
}

class StickerRotation {
  /// Rotation of the Sticker
  final double _rotation;

  /// Direction of the [rotation] value
  final RotationDirection direction;

  const StickerRotation(
    this._rotation, {
    this.direction = RotationDirection.CLOCKWISE,
  });

  double get rotation {
    if (direction == RotationDirection.COUNTER_CLOCKWISE)
      return 360 - _rotation;
    else
      return _rotation;
  }
}

abstract class SnapchatAuthStateListener {
  void onLogin(SnapchatUser user);
  void onLogout();
}

enum SnapchatMediaType {
  /// Share a Photo
  PHOTO,

  /// Share a Video
  VIDEO,

  /// Let the User take their own Photo or Video
  NONE
}

enum RotationDirection { CLOCKWISE, COUNTER_CLOCKWISE }
