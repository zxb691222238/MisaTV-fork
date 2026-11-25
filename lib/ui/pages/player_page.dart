import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../parse_play.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/platform/sleep_inhibitor.dart';
import '../../core/platform/window_service.dart';
import '../../models/player_fit.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../models/video_download.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/hyms_captcha_dialog.dart';
import '../widgets/mouse_drag_scroll.dart';
import '../widgets/player_overlay_settings.dart';
import '../widgets/player_key_help.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/volume_hud.dart';
import '../widgets/volume_sheet.dart';
import '../../services/drive/drive_line_hint.dart';
import '../../services/dlna/dlna.dart';
import '../../services/download/video_download_service.dart';
import '../../services/torrent/magnet.dart';
import '../../services/boss_key/boss_key_service.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/player/auto_line_switch.dart';
import '../../services/player/drive_slow_switch.dart';
import '../../services/player/network_speed_smoother.dart';
import '../../services/player/external_players.dart';
import '../../services/player/skip_segments.dart';
import '../../services/player/sleep_timer.dart';
import '../../services/relay/local_relay.dart';
import '../../services/relay/play_seek_probe.dart';
import '../../services/relay/play_speed_meter.dart';
import '../../services/party/party_room.dart';
import '../../services/party/watch_party.dart';
import '../../services/jar_spider/hyms_native.dart';
import '../../services/mpv_extension.dart';
import '../../services/play_page_unwrap.dart';
import '../../services/danmaku/danmaku_endpoints.dart';
import '../../services/danmaku/danmaku_models.dart';
import '../../services/danmaku/danmaku_query.dart';
import '../../services/danmaku/danmaku_service.dart';
import '../../services/danmaku/danmaku_settings.dart';
import '../../services/subtitle/subtitle_models.dart';
import '../widgets/dlna_cast_sheet.dart';
import '../widgets/subtitle_panel.dart';
import '../widgets/video_download_dialog.dart';
import '../../state/app_state.dart';
import '../widgets/drive_login_prompt.dart';

part 'player/cast_part.dart';
part 'player/danmaku_part.dart';
part 'player/download_part.dart';
part 'player/party_part.dart';
part 'player/playback_part.dart';

/// 该播放地址是否是 DASH(MPD) 清单。
///
/// 内置内核是 libmdk + 随包 ffmpeg：前者不认 MPD，后者的 `dash` 只编进去了
/// muxer（`dashenc`），没有 `dashdec` 解复用器 —— 所以 MPD 一定播不了。
/// 用来把 fvp 的 "invalid or unsupported media" 翻译成用户能照做的提示。
bool _looksLikeDashUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('.mpd') ||
      lower.contains('type=mpd') ||
      lower.contains('dash%2bxml');
}

class PlayerSession {
  const PlayerSession({
    required this.detail,
    required this.site,
    required this.flag,
    required this.episodeIndex,
    required this.episodes,
    this.initialPlay,
    this.startPositionMs = 0,
    this.ephemeral = false,
  });

  final VodDetail detail;
  final SourceBean site;
  final String flag;
  final int episodeIndex;
  final List<Episode> episodes;

  /// 已取到的播放地址；为 null 时播放器页自己取链（详情页因此可以秒开播放器）。
  final PlayResult? initialPlay;
  final int startPositionMs;

  /// 临时会话（WebDAV 目录 / 磁力流等不属于订阅源的直链）：
  /// 不写观看历史、不记跳过片头片尾 —— 这些记录在收藏页无法恢复。
  final bool ephemeral;
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.session,
    this.onExit,
    this.onSwitchSource,
    this.onVideoAspect,
  });

  final PlayerSession session;

  /// 独立窗口模式下退出播放器（关闭子窗口）；为空 = 普通路由返回。
  final Future<void> Function()? onExit;

  /// 独立窗口模式下「换源」：把片名交给主窗口搜索，然后关闭子窗口。
  final Future<void> Function(String keyword)? onSwitchSource;

  /// 独立窗口模式下的竖版适配：拿到视频分辨率后回调（内嵌播放器传 null）。
  final Future<void> Function(double videoWidth, double videoHeight)?
  onVideoAspect;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  late final AnimationController _fsAnim;
  late int _index = widget.session.episodeIndex;

  /// 自动换线 / 换源后，详情、站点、线路和选集都可能变化。
  late VodDetail _detail = widget.session.detail;
  late SourceBean _site = widget.session.site;
  late String _flag = widget.session.flag;
  late List<Episode> _episodes = widget.session.episodes;
  late bool _ephemeral = widget.session.ephemeral;
  bool _opened = false;
  bool _controls = true;
  bool _cursorVisible = true;
  bool _sleepHeld = false;
  bool _buffering = true;

  /// 缓冲超过一小段时间才亮转圈：轻微补帧不会闪一下遮住画面。
  bool _bufferingHint = false;
  Timer? _bufferingHintTimer;
  bool _playing = false;
  bool _fullscreen = false;
  bool _fsToggling = false;
  bool _resolving = false;
  bool _completedHandled = false;
  bool _mpvReady = false;

  /// 睡眠定时器：到点暂停当前播放。
  ///
  /// 放在播放器页而不是全局 AppState：定时器的生命周期应该跟着这一集走，
  /// 关掉播放器就自然失效，避免退出后还在后台倒计时。
  late final SleepTimer _sleepTimer = SleepTimer(
    onExpire: _onSleepTimerExpired,
    onChanged: (_) {
      if (mounted) setState(() {});
    },
  );

  /// 定时器到点：暂停播放并提示。
  void _onSleepTimerExpired() {
    if (!mounted) return;
    _controller?.pause();
    setState(() => _playing = false);
    _toast('睡眠定时器已到点，播放已暂停');
  }
  String _error = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _rate = 1.0;
  double _volume = 1.0;
  bool _danmakuEnabled = false;
  List<DanmakuLine> _danmaku = const [];

  /// 当前集拉到的全量弹幕；屏蔽词变化时据此重新过滤。
  List<DanmakuLine> _allDanmaku = const [];
  int _danmakuSeq = 0;
  String _subtitleStatus = '';
  PlayerFit _fit = PlayerFit.contain;
  int _skipIntro = 0;
  int _skipOutro = 0;
  String _skipInheritedFrom = '';
  bool _outroFired = false;

  /// 已经写进当前内核的缓冲参数：设置页改动后据此判断要不要重新下发。
  double? _lastAppliedBufferMin;
  double? _lastAppliedBufferMax;
  bool _holdingRate = false;
  double? _rateBeforeHold;
  bool _mini = false;

  /// 运行时识别出的直播流：隐藏进度条 / 弹幕 / 片头片尾，底部显示「直播」。
  bool _live = false;

  /// 手机全屏横向滑动进度：拖动起点与拖动中的目标位置（null = 未在拖动）。
  Duration? _seekDragTarget;
  Duration _seekDragBase = Duration.zero;

  /// 进度条右键单击 / 双击判定：双击清除记录，单击取点。
  /// 单击要等过双击窗口才执行，否则第二次按下时第一次的设置已经落盘，撤不回来。
  Timer? _skipTapTimer;
  DateTime? _lastSecondaryTapAt;
  double _lastSecondaryTapDx = 0;

  /// 沉浸观影下窗口本来就全屏，离开播放器时不能把外层沉浸全屏退掉。
  bool _immersiveMode = false;
  bool _landscapeUiApplied = false;
  static const MethodChannel _androidDeviceChannel =
      MethodChannel('com.kniephos.kniephos/sleep_inhibitor');
  bool _portraitFullscreen = false;
  bool _manualOrientationLocked = false;
  String? _verticalDragMode;
  double _androidBrightness = 0.5;
  double _androidSystemVolume = 0.5;
  bool _brightnessOverridden = false;
  bool _gestureHudVisible = false;
  IconData _gestureHudIcon = Icons.brightness_6_rounded;
  String _gestureHudLabel = '';
  double _gestureHudProgress = 0.0;
  Timer? _gestureHudTimer;

  /// 同一集取链进行中的标记：用于忽略重复点击（`_openSeq` 只负责作废旧结果）。
  int? _loadingIndex;

  /// 正在切换外部 MPV：防止连续点击开出多个播放器。
  bool _openingMpv = false;

  /// 已把当前播放地址交给外部播放器：页面 dispose 时不能回收取流 JVM，
  /// 否则外部播放器随后请求本机 `/chunk` 只会拿到 404。
  bool _handedToExternalPlayer = false;

  /// 该集是否已经因「本机取流地址打不开」自动重取过一次，防止死循环。
  int _mediaRetriedEpisode = -1;

  /// 该集是否已经因初始化超时尝试过绕过本机中继直连，防止反复超时。
  int _directRetriedEpisode = -1;

  /// 该集是否已经因「网盘直链读不出索引」改用壳内 serve host 重取过。
  ///
  /// 夸克/UC/百度的直链交给 libmdk 打开大 mkv 时会纯顺序读、拿不到尾部
  /// Cues（实测 25 秒只读到 142MB / 6422MB 后超时）；而同一份数据经壳的
  /// `/chunk` 是秒开。这条重试只在直链超时后走一次，避免死循环。
  int _serveRetriedEpisode = -1;

  /// 直链持续低速的采样计时器与防重入标记。
  Timer? _driveSlowTimer;
  int _driveSlowEpisode = -1;
  int _driveSlowSwitchedEpisode = -1;
  bool _driveSwitchInFlight = false;

  /// 已经确认「网盘直链读不出尾部索引」的线路（`站点|线路`）。
  ///
  /// 夸克/UC 的部分大 mkv 交给 libmdk 时会纯顺序读、永远摸不到文件尾的
  /// Cues（实测 18:11:53 玩偶「嫁金钗」6.0GB E08：25 秒走到 209MB / 6422MB）。
  /// 这类线路一旦被证实，同一线路的下一集就**直接**走壳内取流，不再让用户
  /// 每集都白等一次 25 秒超时。换线路 / 换站点不受影响（key 含站点与线路名）。
  final Set<String> _driveServePreferred = {};

  /// 本次打开是否已记录过播放内核错误（原生内核闪退前通常只有这一条线索）。
  bool _errorLogged = false;

  /// 自动换线：已尝试过的「站点|详情|线路|集名」，避免回环。
  final Set<String> _autoTriedAttempts = {};

  /// 已经搜索并尝试过的其他源（同一源只换一次）。
  final Set<String> _autoTriedSources = {};

  /// 自动换线流程进行中（防止多个失败回调同时换线）。
  bool _autoSwitching = false;

  /// 自动换线运行代次：用户手动操作会作废旧的一轮。
  int _autoRunSeq = 0;

  /// 当前这次打开是否已经触发过自动换线（内核 error 回调会重复）。
  bool _autoErrorHandled = false;

  /// 用户手动切集 / 换线路计数；自动流程发现它变化就中止。
  int _manualSeq = 0;

  /// 自动换源搜索的订阅 / 超时 / 完成信号；离开播放器时主动收掉。
  Completer<void>? _autoSearchDone;
  StreamSubscription<SearchProgress>? _autoSearchSub;
  Timer? _autoSearchTimer;

  /// 自动换线正在异步释放旧 controller；手动切换前也要等它完成。
  Future<void>? _controllerDisposePending;

  /// 刚被看门狗判死的那个 controller —— 换路重开时**不必等它释放**。
  ///
  /// ★ 为什么要记这个（2026-11-17 20:01:24 实测，玩偶「嫁金钗」[6.0GB]E08）：
  ///
  ///   看门狗 5.3 秒判定「只顺读、读不到尾部索引」后走换路分支，换路取链
  ///   只花 2.6 秒（20:01:30.3 → 20:01:32.9），但下一集真正开始打开要到
  ///   **20:01:40.9** —— 中间白等 8.0 秒，正好是
  ///   `await old.dispose().timeout(const Duration(seconds: 8))` 的满额超时。
  ///
  ///   而那个 dispose 必然超时：`VideoPlayerController.dispose()` 第一件事是
  ///   `await _creatingCompleter!.future`，等的是原生 `prepare()` 返回；
  ///   而 prepare 正卡在「顺序扫 6.4GB 找 Cues」上，永远不返回。
  ///
  ///   既然我们已经**确知**这只内核卡死了，就不该再为它等 8 秒：直接放弃
  ///   释放（线程池里的僵尸 libmdk 实例不影响新建），立刻打开新地址。
  ///   这是 17.4 秒 → 9.4 秒的关键。
  bool _deadControllerPending = false;

  /// 滚轮调音量的落盘防抖：连续滚动时只在停下后写一次播放设置。
  Timer? _volumeWheelTimer;

  /// 快捷键 / 滚轮调音量时短暂显示的音量条。
  bool _volumeHudVisible = false;
  Timer? _volumeHudTimer;

  /// 本次播放会话的窗口置顶状态（不落盘，离开播放器即复位）。
  bool _alwaysOnTop = false;

  /// 进入小窗前的置顶选择，退出小窗时恢复。
  bool _pinnedBeforeMini = false;
  List<_AudioOption> _audioOptions = const [];
  int? _activeAudio;

  /// 当前这一集已解析出的播放地址（投屏时据此解出真实上游地址）。
  PlayResult? _currentPlay;

  /// `_currentPlay` 对应的集数下标；切集取链过程中它仍指旧集，避免被外部播放器误用。
  int? _currentPlayIndex;

  /// 静音前的音量，取消静音时恢复。
  double _lastVolume = 1.0;
  int _openSeq = 0;
  Timer? _hideTimer;
  Timer? _saveTimer;

  /// 一起看：是否已绑定房间状态监听，以及上次广播时间（节流）。
  bool _partyBound = false;
  int _lastPartyPushAt = 0;
  bool _partyMismatchNotified = false;

  /// 播放器「详情」悬浮层开关与每秒刷新时钟 / 网速的计时器。
  bool _detailsVisible = false;
  Timer? _detailsTimer;


  /// 「详情」用的媒体信息缓存：只在 1 秒采样时读一次 fvp，避免播放器
  /// 每帧回调都把瞬时码率直接画到屏幕上（会剧烈跳动、出现关键帧尖峰）。
  _MediaStats? _mediaStats;

  /// 平滑后的展示值，避免 libmdk 实时码率的尖峰直接上屏。
  final NetworkSpeedSmoother _netSmoother = NetworkSpeedSmoother();
  late AppState _app;

  /// 正在刷新取流（防止连点重复起播放器）。
  bool _refreshing = false;

  /// fvp（libmdk）在桌面端始终接管 video_player；移动端默认不接管，
  /// 安卓端需用户开启 FFmpeg 内核并显式 registerWith 后才走 libmdk/FFmpeg。
  /// 该 getter 只表达「平台是否支持 fvp」，是否真正启用另由 useFfmpeg 决定。
  bool get _mdkEnabled =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// 安卓端在用户开启 FFmpeg 内核时显式注册 fvp：fvp 默认只在桌面接管
  /// video_player，移动端需要主动 registerWith 才会走 libmdk/FFmpeg 解码。
  /// 桌面端由启动处统一注册，这里只在安卓补一次；用静态标记避免重复注册。
  static bool _fvpRegistered = false;
  void _ensureFvp() {
    if (_fvpRegistered || defaultTargetPlatform != TargetPlatform.android) return;
    if (!_app.playerSettings.useFfmpeg) return;
    try {
      registerWith();
      _fvpRegistered = true;
    } catch (_) {
      // 注册失败则退回系统 ExoPlayer，不影响其余播放逻辑
    }
  }

  String get _episodeName =>
      _index >= 0 && _index < _episodes.length ? _episodes[_index].name : '';

  String _episodeKey(int index) {
    final name = index >= 0 && index < _episodes.length
        ? _episodes[index].name.trim()
        : '';
    return name.isEmpty ? '第${index + 1}集' : name;
  }

  /// 独立窗口里按视频分辨率切竖版；内嵌播放器没有回调，什么都不做。
  void _applyVideoAspect(VideoPlayerController controller) {
    final apply = widget.onVideoAspect;
    if (apply == null && !_isAndroid) return;
    var size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      // fvp 偶尔不给 VideoPlayerValue 尺寸，退回 libmdk 的 MediaInfo。
      final stats = _readMediaStats();
      if (stats == null) return;
      size = Size(stats.width.toDouble(), stats.height.toDouble());
    }
    if (size.width <= 0 || size.height <= 0) return;
    if (apply != null) { unawaited(apply(size.width, size.height)); }
    if (_isAndroid &&
        !_manualOrientationLocked &&
        _app.playerSettings.autoLandscape) {
      final isPortraitVideo = size.height > size.width * 1.05;
      unawaited(_applyAndroidOrientation(portrait: isPortraitVideo));
    }
  }

  void _syncAudioTracks(VideoPlayerController controller) {
    if (!_mdkEnabled || controller != _controller) return;
    try {
      final info = controller.getMediaInfo();
      final list = <_AudioOption>[];
      final audio = info?.audio;
      if (audio != null) {
        for (final item in audio) {
          final meta = item.metadata;
          list.add(
            _AudioOption(
              index: item.index,
              codec: item.codec.codec,
              channels: item.codec.channels,
              language: (meta['language'] ?? meta['lang'] ?? '').toString(),
              title: (meta['title'] ?? meta['handler_name'] ?? '').toString(),
            ),
          );
        }
      }
      final active = controller.getActiveAudioTracks();
      if (!mounted) return;
      setState(() {
        _audioOptions = list;
        _activeAudio = (active != null && active.isNotEmpty)
            ? active.first
            : (list.isNotEmpty ? list.first.index : null);
      });
    } catch (_) {
      // 非 fvp / 内核未就绪：没有音轨信息，不显示音轨入口
    }
  }

  @override
  void initState() {
    super.initState();
    // 全屏切换用纯 Flutter 的缩放/淡入过渡（只走合成层，不再逐帧 Resize 窗口）。
    _fsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
    MpvExtension.instance.isInstalled.then((value) {
      if (mounted) setState(() => _mpvReady = value);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) {
      // 设置页改了缓冲参数：当前播放器立刻跟随，不必等下一集起播。
      final settings = _app.playerSettings;
      if (settings.bufferMinSec != _lastAppliedBufferMin ||
          settings.bufferMaxSec != _lastAppliedBufferMax) {
        _lastAppliedBufferMin = settings.bufferMinSec;
        _lastAppliedBufferMax = settings.bufferMaxSec;
        final controller = _controller;
        if (controller != null) _applyBufferRange(controller);
      }
      return;
    }
    _opened = true;
    _app = AppScope.of(context);
    // 安卓端：用户开启 FFmpeg 内核时让 fvp 接管 video_player（桌面端已在启动处注册）。
    _ensureFvp();
    // 设置里的全局无痕模式：本次播放默认就不写历史 / 进度。
    // 播放器里的「无痕播放」开关仍可对本次播放单独关掉，不改全局设置。
    _ephemeral = _ephemeral || _app.playerSettings.incognito;
    if (!_partyBound) {
      _partyBound = true;
      _app.watchParty.addListener(_onPartyUpdate);
    }
    _lastAppliedBufferMin = _app.playerSettings.bufferMinSec;
    _lastAppliedBufferMax = _app.playerSettings.bufferMaxSec;
    _immersiveMode = _app.playerSettings.immersiveMode;
    // 移动端播放时自动横屏：进入播放器即请求横屏，并隐藏系统栏（沉浸模式）
    // 避免系统状态栏/导航栏的白色条盖住播放器按键；退出时（dispose）恢复。
    if (_isMobile && _app.playerSettings.autoLandscape) {
      unawaited(
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
      _landscapeUiApplied = true;
      _portraitFullscreen = false;
    }
    if (_isAndroid) {
      unawaited(_syncAndroidDeviceState());
    }
    BossKeyService.instance.bindPlayer(
      this,
      pause: _pauseForBossKey,
      resume: _resumeFromBossKey,
    );
    _rate = _app.playerSettings.speed;
    _fit = normalizePlayerFit(_app.playerSettings.fit);
    _volume = _app.playerSettings.volume.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    _danmakuEnabled = _app.danmakuSettings.enabled;
    // 「详情」开关跨启动记忆：上次开着就继续开，关掉也保持关闭。
    _detailsVisible = _app.playerSettings.overlayVisible;
    if (_detailsVisible) _startDetailsTimer();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openEpisode(
        index: widget.session.episodeIndex,
        play: widget.session.initialPlay,
        startMs: widget.session.startPositionMs,
      ),
    );
  }

  void _onPlayerValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // libmdk 对未知时长的直播会给一个接近 Duration 上限的时长；识别到以后
    // 不再显示进度、弹幕与片头片尾逻辑。
    final live = _live || value.duration > const Duration(hours: 24);
    setState(() {
      _live = live;
      _position = value.position;
      _duration = value.duration;
      _playing = value.isPlaying;
      _buffering = value.isBuffering;
      if (!value.isPlaying) _cursorVisible = true;
      if (value.hasError) {
        _error = value.errorDescription ?? '播放失败';
        _buffering = false;
      }
    });
    _syncBufferingHint(_buffering);
    if (value.hasError && !_errorLogged) {
      _errorLogged = true;
      AppLog.w(
        'player',
        '播放内核报错：$_error url=${redactUrl(_currentPlay?.url ?? '')}',
      );
    }
    if (value.hasError && !_autoErrorHandled && !_autoSwitching) {
      _autoErrorHandled = true;
      unawaited(
        _scheduleAutoSwitch(
          value.errorDescription ?? '播放失败',
          startMs: value.position.inMilliseconds,
        ),
      );
    }
    _syncSleepInhibitor();
    // 一起看：房主把进度广播到局域网（内部按 800ms 节流）。
    final party = _app.watchParty;
    if (party.hosting && !_live) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPartyPushAt >= 1500) {
        _lastPartyPushAt = now;
        party.publish(
          PartyState(
            title: _detail.name,
            episodeName: _episodeName,
            episodeIndex: _index,
            positionMs: value.position.inMilliseconds,
            playing: value.isPlaying,
          ),
        );
      }
    }
    if (!_live && value.isCompleted && !_completedHandled) {
      _completedHandled = true;
      _onCompleted();
    }
    if (!_live &&
        !_outroFired &&
        shouldSkipOutro(
          value.position.inMilliseconds,
          value.duration.inMilliseconds,
          _skipOutro,
          _outroFired,
        )) {
      _outroFired = true;
      _onOutroReached();
    }
  }

  void _onOutroReached() {
    if (!_app.playerSettings.autoPlayNext) return;
    if (_index + 1 >= _episodes.length) return;
    _toast('已跳过片尾，播放下一集');
    _switchTo(_index + 1);
  }

  Future<bool> _openEpisode({
    required int index,
    PlayResult? play,
    int startMs = 0,
    bool allowLogin = true,
    bool bypassRelay = false,
    bool autoAttempt = false,
  }) async {
    final app = _app;
    if (!mounted || index < 0 || index >= _episodes.length) return false;
    if (!autoAttempt) {
      // 用户手动切集 / 重试：作废正在进行的自动换线，并允许重新尝试全部线路。
      _manualSeq++;
      _autoErrorHandled = false;
      _autoTriedAttempts.clear();
      _autoTriedSources.clear();
      _autoRunSeq++;
      _autoSwitching = false;
      final done = _autoSearchDone;
      if (done != null && !done.isCompleted) done.complete();
      final sub = _autoSearchSub;
      if (sub != null) unawaited(sub.cancel());
      _autoSearchDone = null;
      _autoSearchSub = null;
      _autoSearchTimer?.cancel();
      _autoSearchTimer = null;
    }
    _driveSlowTimer?.cancel();
    _driveSlowEpisode = -1;
    if (index != _index) {
      _directRetriedEpisode = -1;
      _serveRetriedEpisode = -1;
      // 换集了：上一条「判死待释放」的标记与这一集无关，清掉。
      _deadControllerPending = false;
    }
    // 同一集正在取链时重复点击直接忽略：否则会并发拉多个常驻取流进程、
    // 同时初始化多个 controller，最后真的会同时播放好几份。
    if (play == null && _loadingIndex == index) return false;
    final seq = ++_openSeq;
    if (play == null) {
      _loadingIndex = index;
      setState(() {
        _resolving = true;
        _error = '';
      });
    }
    PlayResult? resolved;
    try {
      resolved = play ?? await _resolve(index);
    } catch (e) {
      if (seq != _openSeq || !mounted) return false;
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '取链失败：$e';
      });
      _afterFailure('取链失败：$e', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (seq != _openSeq || !mounted) return false;
    if (resolved == null) {
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '没有取到播放地址';
      });
      _afterFailure('没有取到播放地址', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    var target = resolved;
    try {
      if (target.parse != 0 && target.externalLink.isEmpty) {
        target = await resolveParsedPlay(
          context,
          app,
          _site,
          target,
          rawUrl: _episodes[index].url,
        );
        if (seq != _openSeq || !mounted) return false;
      }
      // 详情页“立即播放”传来的地址也可能是云播 HTML 页面。
      target = await app.unwrapPlayPage(target);
    } catch (e) {
      if (seq != _openSeq || !mounted) return false;
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '解析播放地址失败：$e';
      });
      _afterFailure('解析播放地址失败：$e', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (seq != _openSeq || !mounted) return false;
    // 源站把海报 / 截图当播放地址返回：fvp/libmdk 在图像解码路径上可能整进程闪退，
    // 打开前直接拦下并提示换线路。
    if (target.playable && looksLikeImageMediaUrl(target.url)) {
      if (play == null) _loadingIndex = null;
      AppLog.w('player', '拒绝播放图片地址 ${redactUrl(target.url)}');
      setState(() {
        _error = '该线路返回的是图片地址（源站解析异常），请改用其他线路';
        _resolving = false;
        _buffering = false;
      });
      _afterFailure('该线路返回的是图片地址', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (!target.playable) {
      // 换集时没登录对应网盘：直接弹扫码，成功后自动重试一次。
      // 可选增强（哔哩）跳过：没 Cookie 也会回低画质直链，重试只会白跑一次。
      if (allowLogin) {
        final hint = driveHintFromMessage(target.message);
        if (hint != null && hint.supported && !hint.optional) {
          if (!mounted) return false;
          final ready = await promptDriveLogin(
            context,
            hint,
            message: target.message,
          );
          if (!mounted) return false;
          if (ready) {
            _loadingIndex = null;
            await _openEpisode(
              index: index,
              startMs: startMs,
              allowLogin: false,
              autoAttempt: autoAttempt,
            );
            return false;
          }
        }
      }
      if (play == null) _loadingIndex = null;
      final message = target.message.isEmpty ? '无法播放这一集' : target.message;
      setState(() {
        _error = message;
        _resolving = false;
      });
      _afterFailure(message, autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (play == null) _loadingIndex = null;
    // ★ 这条线路先前已被证实「网盘直链读不出尾部索引」，直接走壳内取流。
    //
    //   否则用户每换一集都要再白等一次 25 秒超时（实测 18:11:53 → 18:12:18
    //   点 E08 白等 25 秒才失败；换到 1.3GB 的 E24 立刻能播 —— 小文件
    //   libmdk 能一路顺读到尾，6GB 的 E08 就永远等不到）。
    //   只对「同一站点 + 同一线路名」生效，换线路不受影响。
    // ★ 这里**不要**加 `play == null`。
    //
    //   `preferServe` 的语义是「这条线路的直链读不动」，和「这一集有没有
    //   预取到地址」无关。加了那个条件后，从详情页点播 / 页面内连点下一集
    //   （`play != null`）都会绕过它，于是每集都要重新走一遍
    //   「直链 → 等判死 → 换壳内」。
    //
    //   实测代价（2026-11-18 15:42，E11 那一集）：
    //
    //     15:42:04.323  K8m5IUFf  start=0
    //     15:42:04.524  206 len=8388608          首段 8MB，0.2 秒
    //     15:42:05.070  K8m5IUFf  start=8388608
    //     15:42:26.940  K8m5IUFf  start=41943040    ← 22 秒后才要下一段
    //
    //     那一个 32MB 分片拉了 22 秒 = 1.5 MB/s。这 22 秒里僵尸请求全被
    //     拒绝了（日志只有「拒绝僵尸请求」，零字节）—— 不是带宽被分走，
    //     是这条直链本身就这么慢。
    //
    //   去掉条件后：第一集判死一次（约 6 秒），后续每集直接从壳内取流
    //   （约 5 秒），不再每集白等 20 秒，也不再产生僵尸播放器。
    final preferServe =
        _driveServePreferred.contains('${_site.key}|$_flag') &&
        _site.isJarSpider &&
        !bypassRelay;
    if (preferServe && PlayPageUnwrap.isDriveCdnUrl(target.url)) {
      AppLog.i(
        'player',
        '该线路直链读不动，直接走壳内取流 index=$index url=${redactUrl(target.url)}',
      );
      final warm = await app.sourceService.replayViaServe(
        site: _site,
        config: app.config ?? const SiteConfig(),
        flag: _flag,
        rawUrl: _episodes[index].url,
      );
      if (seq != _openSeq || !mounted) return false;
      if (warm != null && warm.playable) {
        target = warm;
      } else {
        AppLog.w('player', '壳内取流未取到，本次仍用直链 index=$index');
        _driveServePreferred.remove('${_site.key}|$_flag');
      }
    }
    // 打开前的「64KB 头体检」曾经在这里：拉文件头看 SeekHead 有没有 Cues 指针，
    // 没有就直接走壳内取流。2026-11-17 全天实测 41 次体检里 **判出 linearOnly
    // 0 次** —— 能取到头的文件（26 次）SeekHead 里都写了 Cues，取不到头的
    // （11 次 403）只能回 unknown。也就是说它一次都没能省下看门狗的时间，
    // 反而每次白花 0.2~0.6 秒。已删除，统一由下面的顺读看门狗负责。
    final source = bypassRelay
        ? target
        : app.preparePlay(target, forceRelay: true);
    _currentPlay = target;
    _currentPlayIndex = index;
    final resource = '${_detail.sourceKey}|${_detail.id}';
    final episodeKey = _episodeKey(index);
    final skip = _ephemeral ? null : app.skipFor(resource, episodeKey);
    final effectiveStart = startMs > 0 ? startMs : (skip?.intro ?? 0) * 1000;
    setState(() {
      _index = index;
      _resolving = true;
      _error = '';
      _buffering = true;
      _completedHandled = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _subtitleStatus = '';
      _danmaku = const [];
      _allDanmaku = const [];
      _danmakuSeq++;
      _skipIntro = skip?.intro ?? 0;
      _skipOutro = skip?.outro ?? 0;
      _skipInheritedFrom = skip?.inheritedFrom ?? '';
      _outroFired = false;
      _audioOptions = const [];
      _activeAudio = null;
      _errorLogged = false;
      _mediaStats = null;
      _netSmoother.reset();
      // 换集/换线路：中继的累计字节归零，否则上一集的流量会算进本集速度。
      PlaySpeedMeter.instance.reset();
      _live = false;
    });
    // 换集 / 换线路：立刻掐掉中继上一条播放的转发会话。
    //
    // 播放器换 URL 时不会通知中继，旧那一集的转发会继续从上游拉数据 ——
    // 实测 2026-11-18 13:21：82.2GB 奥德赛开播后，前一部「复仇者联盟」
    // （Ent9tGSS）的上游连接还在拉，一直拉到 13:21:58。结果是同一个 CDN
    // 连接池被多个片分掉：单独跑 32MB 分片能到 12.27 MB/s，实际播放只有
    // 4.47 MB/s，而这条片码率 5.90 MB/s —— 立刻卡。
    LocalRelay.instance.releasePlaySessions();
    // ★ 这一集如果之前被判死过，先解除标记 —— 用户主动点回来就该给它
    //   一次机会。真读不动的话看门狗 2.5 秒会再判一次，代价可接受。
    LocalRelay.instance.revivePlayTarget(target.url);
    // ★ 同时清空探针窗口。这里正好是「确实换片了」的语义边界。
    //
    //   探针现在是滑动时间窗口，不清就会把上一集的样本带进新一集：
    //   实测 2026-11-18 14:00:45 直链判死后换到 `/chunk`，chunk 自己只发了
    //   1 条请求，但窗口里还积压着 9 条直链的样本 —— 250 毫秒后
    //   `looksSequentialOnly()` 仍然成立，刚打开的 chunk 立刻被判死。
    //
    //   放在这里而不是 `_watchSequentialOnly()` 里，是因为后者每个实例都会
    //   调一次，连点几集时会互相清空（那正是上一版的 bug）。
    PlaySeekProbe.instance.reset();
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerValue);
    // 必须等旧 controller 释放完再建新的：fvp/libmdk 的销毁与初始化都在原生侧，
    // 换集/换线路时并发会让播放内核在驱动/解析线程上崩溃（整进程闪退，没有 Dart 栈）。
    //
    // ★ 但要**限时**。`VideoPlayerController.dispose()` 里的第一件事是
    //   `await _creatingCompleter!.future`（video_player.dart:707），而那个
    //   completer 要等 `_videoPlayerPlatform.createWithOptions` 返回，也就是
    //   fvp 的 `player.prepare()` 成功回来。上游卡住时 prepare 不返回，
    //   dispose 就永远挂着 —— 用户侧看到的是「点了新的一集，画面一直黑」。
    //   实测：玩偶「嫁金钗」夸克原画 5.7GB E13，12:44:22 开始打开 → 12:54:09
    //   才报 timeout，中间 562 秒没有任何新动作，正是卡在这里。
    //
    // ★★ 但**已经判死的那个**不必等（见 _deadControllerPending 的说明）：
    //   看门狗刚确认它卡在「顺序扫 Cues」上，dispose 必然满额超时。
    //   实测 20:01:24 那次换路，取链只花 2.6 秒，却为 dispose 白等 8.0 秒
    //   （20:01:32.9 → 20:01:40.9 才开始打开 chunk）。用户体感就是
    //   「明明已经切过去了，还要再黑屏 8 秒」。
    if (!_deadControllerPending) {
      try {
        await old?.dispose().timeout(const Duration(seconds: 8));
      } catch (_) {
        // 旧实例释放失败 / 超时都不影响新一集
      }
    } else {
      // 判死的那只：后台放着释放，绝口不等它。
      _deadControllerPending = false;
      AppLog.i('player', '跳过已判死内核的释放等待（省 8s），直接打开新地址');
      unawaited(
        old?.dispose().timeout(const Duration(seconds: 60)).catchError((_) {}),
      );
    }
    final pendingDispose = _controllerDisposePending;
    if (pendingDispose != null) {
      try {
        // ★ 必须限时：`VideoPlayerController.dispose()` 内部先
        //   `await _creatingCompleter!.future`，而那个 completer 要等原生
        //   `prepare()` 返回。上游被 CDN 压到 0.1MB/s 时它几分钟都不返回，
        //   dispose 就会无限挂起（实测 12:44:22 → 12:54:09，562 秒）。
        //   等不到就放弃等待，继续开下一集 —— 宁可多留一个僵尸内核，
        //   也不能让整页黑屏。
        await pendingDispose.timeout(const Duration(seconds: 5));
      } catch (_) {
        // 自动换线释放失败 / 超时都不阻断手动切换
      }
    }
    if (seq != _openSeq || !mounted) return false;
    AppLog.i(
      'player',
      '开始打开 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
          'url=${redactUrl(source.url)}',
    );
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        httpHeaders: source.headers,
      );
      _controller = controller;
      controller.addListener(_onPlayerValue);
      // 4K / HDR 线路经过本机中继时，个别清单会让 fvp 一直没首帧；
      // 25 秒没有初始化完成就放弃，后面会尝试绕过中继直连。
      //
      // ★ 但「等满 25 秒」对大文件网盘直链来说太浪费：实测 libmdk 打开
      //   夸克 6.0GB mkv 时会从 0 开始纯顺序读，25 秒只走到 209MB，
      //   期间**没有任何请求落在文件尾部**（Cues 索引在 6.42GB）。
      //   这种模式注定打不开 —— 等 25 秒只是让用户多黑屏 20 秒。
      //   所以并行挂一个看门狗：中继的 PlaySeekProbe 一旦确认「只顺读、
      //   从不摸尾部、5 秒还不到 20%」，就提前放弃这一次，立刻换壳内取流。
      final initSw = Stopwatch()..start();
      final deathWatch = _watchSequentialOnly(source.url);
      try {
        await Future.any<void>([
          controller.initialize().timeout(const Duration(seconds: 25)),
          deathWatch.future,
        ]);
        if (deathWatch.fired()) {
          // 看门狗先到：抛一个带标记的超时，让下面的失败分支走「换路重取」。
          //
          // ★ 同时打上「这只内核已判死」的标记：它正卡在原生 prepare 里
          //   （顺序扫 Cues），dispose 一定等到超时。换路时不该为它再等 8 秒。
          _deadControllerPending = true;
          // ★★ 立刻掐掉这条已经判死的直链转发。
          //
          //   不掐的话，从判死到换路取链成功之间（实测 14:00:45.25 →
          //   14:00:53.02，约 8 秒）旧连接还在从 CDN 拉 32MB 分片 ——
          //   日志里 14:00:47 / 14:00:49 / 14:00:52 三条 `bytes=...` 就是它。
          //   这 8 秒的带宽全是浪费，而且会和壳内取流抢同一个 CDN 名额。
          AppLog.i('player', '判死的直链连接立刻释放');
          LocalRelay.instance.releasePlaySessions();
          throw TimeoutException(
            '顺序读 ${PlaySeekProbe.instance}',
            const Duration(seconds: 25),
          );
        }
      } finally {
        deathWatch.cancel();
      }
      AppLog.i(
        'player',
        '打开就绪 ${_episodeName.isEmpty ? '正片' : _episodeName} '
            'initialize=${initSw.elapsedMilliseconds}ms',
      );
      // 缓冲参数要在起播前设好：fvp 的 bufferRange 只影响后续拉流。
      _applyBufferRange(controller);
      final live = _detectLive(controller);
      _live = live;
      await controller.setPlaybackSpeed(_rate);
      await controller.setVolume(_volume);
      final durationMs = controller.value.duration.inMilliseconds;
      // 片头记录可能超过片长（换集后沿用旧设置）：越界就不跳。
      // 直播没有时间轴，不做起播跳转。
      final canSeek =
          !live &&
          (startMs > 0 ||
              durationMs <= 0 ||
              effectiveStart < durationMs - 1000);
      final appliedStart = canSeek ? effectiveStart : 0;
      if (appliedStart > 0) {
        await controller.seekTo(Duration(milliseconds: appliedStart));
      }
      await controller.play();
      if (seq != _openSeq || !mounted) return false;
      AppLog.i(
        'player',
        '打开成功 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
            'url=${redactUrl(source.url)}',
      );
      _mediaRetriedEpisode = -1;
      _directRetriedEpisode = -1;
      _serveRetriedEpisode = -1;
      setState(() {
        _resolving = false;
        _buffering = false;
        _live = live;
        _position = controller.value.position;
        _duration = controller.value.duration;
        _playing = controller.value.isPlaying;
      });
      _syncSleepInhibitor();
      _syncAudioTracks(controller);
      if (!bypassRelay &&
          PlayPageUnwrap.isRangeThrottledDriveCdn(target.url)) {
        _watchDriveThroughput(
          index: index,
          target: target,
          startMs: appliedStart,
        );
      }
      _applyVideoAspect(controller);
      if (!_ephemeral) {
        await app.recordHistory(
          detail: _detail,
          site: _site,
          flag: _flag,
          episodeName: _episodeName,
          episodeIndex: _index,
          url: target.url,
          rawUrl: _episodes[_index].url,
          headers: target.headers,
          positionMs: appliedStart,
        );
      }
      _startSaveTimer();
      _showControls();
      // ★ 上次这集用过哪条在线字幕，就自动挂上（"记忆"）。
      //
      //   只在本地缓存命中时生效 —— 不联网、不阻塞起播。用户想换一条
      //   仍可点字幕按钮手动选（面板里会显示「已缓存 N 条」）。
      if (!live) unawaited(_autoRestoreSubtitle());
      if (_danmakuEnabled && !live) unawaited(_loadDanmaku());
      return true;
    } catch (e) {
      // ★ 先记日志，再判断要不要继续。
      //
      //   原先是「seq 变了 / 页面已关 → 直接 return false」，连日志都不打。
      //   结果：用户点一条卡死的线路，25 秒超时之后**日志里什么都没有**，
      //   既看不到超时、也看不到「改用直连重试」—— 排查时只能靠猜。
      //   实测 13:49:44 与 13:51:01 两次点 5.7GB E05 就是这样：只有
      //   「开始打开」，之后 129 秒一片空白。
      //
      //   日志是观测手段，不该被状态守卫吞掉；`seq`/`mounted` 只决定后面
      //   要不要 setState / 自动重试。
      final stale = seq != _openSeq;
      AppLog.e(
        'player',
        '打开失败 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
            '${stale ? '(已切走) ' : ''}url=${redactUrl(target.url)}',
        e,
      );
      if (stale || !mounted) return false;
      final timedOut = e is TimeoutException;
      // ★ 网盘直链读不出索引 → 立刻改用壳内 serve host 的 `/chunk` 重取。
      //
      //   必须放在 dispose **之前**：`VideoPlayerController.dispose()` 第一件事是
      //   `await _creatingCompleter!.future`，而 prepare 卡住时它不返回，这里要
      //   白等 5 秒（实测 18:12:18 失败 → 18:12:23 才走到下面的分支）。
      //   更糟的是这 5 秒里用户往往已经点了别的线路，`seq` 一变，换路分支就
      //   永远进不去 —— 18:11:53 那次就是这样：失败后 0.9 秒用户换了 E24，
      //   日志里连一条「改用壳内取流」都没有。
      //
      //   实测依据（2026-11-17 18:11:53，玩偶「嫁金钗」[6.0GB]E08.mkv，夸克直链）：
      //     libmdk 从 0 开始按 32MB 步长纯顺序读，25 秒只走到 209MB / 6422MB，
      //     期间**一次也没请求文件尾部**；mkv 的 Cues 索引在文件尾，
      //     读不到索引就只有黑屏。同一部剧的「叫金钗 DV」走 JVM `/chunk`：
      //     18:13:50 开始 → 18:13:53 就绪，initialize=2768ms。
      final driveDirect = PlayPageUnwrap.isDriveCdnUrl(target.url);
      if (!autoAttempt &&
          timedOut &&
          driveDirect &&
          _serveRetriedEpisode != index &&
          _site.isJarSpider &&
          index >= 0 &&
          index < _episodes.length) {
        _serveRetriedEpisode = index;
        // 记住「这条线路的网盘直链读不动」：同一线路的下一集直接走壳内取流，
        // 不再让用户每集都白等一次超时。
        _driveServePreferred.add('${_site.key}|$_flag');
        AppLog.w(
          'player',
          '网盘直链读不到索引，改用壳内取流重试 index=$index '
              'url=${redactUrl(target.url)}',
        );
        setState(() {
          _resolving = true;
          _buffering = true;
          _error = '';
        });
        _toast('大文件直链读取超时，正在改用壳内取流');
        unawaited(() async {
          final again = await app.sourceService.replayViaServe(
            site: _site,
            config: app.config ?? const SiteConfig(),
            flag: _flag,
            rawUrl: _episodes[index].url,
          );
          if (!mounted) return;
          if (again == null || !again.playable) {
            AppLog.w(
              'player',
              '壳内取流也未取到，改走直连（本集不再重试壳内）index=$index',
            );
            // ★ 这里**不能**把 `_serveRetriedEpisode` 重置回 -1。
            //
            //   实测 2026-11-18 11:02:43 → 11:03:02 出现过死循环：壳内取流失败
            //   → 重置标记 → 用直链重开 → 看门狗 2.5 秒又判死 → 再次尝试壳内
            //   → 又失败……每 6.5 秒一轮，用户看到的是「一直在转圈」。
            //
            //   现在保留标记：本集的壳内取流已经试过且失败了，就老实用直链，
            //   由看门狗之外的正常流程处理（`bypassRelay: true` 让 libmdk 自己
            //   去顺序读，5.7GB 虽然慢但不至于原地打转）。
            _driveServePreferred.remove('${_site.key}|$_flag');
            unawaited(
              _openEpisode(
                index: index,
                play: target,
                startMs: startMs,
                bypassRelay: true,
              ),
            );
            return;
          }
          unawaited(_openEpisode(index: index, play: again, startMs: startMs));
        }());
        return false;
      }
      final controller = _controller;
      _controller = null;
      controller?.removeListener(_onPlayerValue);
      try {
        // 同上：prepare 卡住时 dispose 会无限挂起，失败分支也必须限时，
        // 否则后面「自动重新取链 / 换源」的重试永远不会开始。
        await controller?.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {
        // 释放失败不影响后续提示 / 重新取链
      }
      // ★ `await` 之后必须重新检查 mounted：dispose 释放内核可能要几百毫秒，
      //   这期间用户完全可能已经退出播放页（或切集把本页 pop 掉）。
      //   下面几处 `setState` 都在这条 await 之后 —— 漏检会在已销毁的
      //   State 上调 setState，抛 `Null check operator used on a null value`
      //   （栈顶是 framework.dart 的 State.setState）。实测今天报过 6 次，
      //   每次都是「某条线路失败后立刻切集 / 返回」的场景。
      if (seq != _openSeq || !mounted) return false;
      // 加固壳/网盘源的地址是本机 JVM 的 /chunk、/proxy：JVM 已退出或端口没起来时
      // fvp 只会报 invalid or unsupported media。自动重新取链一次（会重起常驻进程）。
      final localSpiderUrl =
          target.url.contains('127.0.0.1') &&
          (target.url.contains('/chunk') || target.url.contains('/proxy'));
      // 4K / 大码率清单经中继初始化超时：再试一次直连上游，避免一直转圈。
      // 自动换线尝试不再占用时间做直连重试，直接交给下一条线路。
      if (!autoAttempt &&
          timedOut &&
          !driveDirect &&
          !bypassRelay &&
          source.url != target.url &&
          _directRetriedEpisode != index) {
        _directRetriedEpisode = index;
        AppLog.w(
          'player',
          '初始化超时，改用直连上游地址重试 index=$index url=${redactUrl(target.url)}',
        );
        setState(() {
          _resolving = true;
          _buffering = true;
          _error = '';
        });
        _toast('线路加载超时，正在尝试直连播放');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _openEpisode(
                index: index,
                play: target,
                startMs: startMs,
                bypassRelay: true,
              );
            }
          }),
        );
        return false;
      }
      if (!autoAttempt && localSpiderUrl && _mediaRetriedEpisode != index) {
        _mediaRetriedEpisode = index;
        AppLog.w('player', '本机取流地址打不开，自动重新取链一次 index=$index');
        setState(() {
          _resolving = true;
          _error = '';
        });
        _toast('取流进程未就绪，正在重新取链');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (mounted) _openEpisode(index: index, startMs: startMs);
          }),
        );
        return false;
      }
      // 远程直链被防盗链拒绝（403 / 过期签名）时，fvp 同样只报
      // `invalid or unsupported media`。历史续播复用的是上一次解析出的地址，
      // 旧记录没存请求头、新记录的头也可能过期 —— 重新取一次链即可恢复。
      final mediaOpenFailed =
          e is PlatformException && '$e'.contains('invalid or unsupported media');
      final canResolveAgain =
          index >= 0 &&
          index < _episodes.length &&
          _episodes[index].url.trim().isNotEmpty &&
          _episodes[index].url != target.url &&
          !_looksLikeDashUrl(target.url);
      if (!autoAttempt &&
          mediaOpenFailed &&
          canResolveAgain &&
          _mediaRetriedEpisode != index) {
        _mediaRetriedEpisode = index;
        AppLog.w(
          'player',
          '播放地址打不开，自动重新取链一次 index=$index url=${redactUrl(target.url)}',
        );
        setState(() {
          _resolving = true;
          _buffering = true;
          _error = '';
        });
        _toast('播放地址可能已过期，正在重新获取');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _openEpisode(index: index, startMs: startMs);
          }),
        );
        return false;
      }
      _mediaRetriedEpisode = -1;
      // DASH(MPD) 线路：内置内核（libmdk + 随包 ffmpeg 只有 muxer、没有 dashdec）
      // 解不了这种清单，fvp 只会回 "invalid or unsupported media"。这不是
      // 网络或防盗链问题，换线路才有用 —— 给出可操作的说明，而不是英文原文。
      // 实测：wex 的 BiliGuard（高中课堂 / 少儿教育）只下发 dash+xml。
      final dashLine = _looksLikeDashUrl(target.url);
      final message = timedOut
          ? '播放器加载超时：该线路可能是 4K / HDR 或编码不受支持，请换线路或改用外部播放器'
          : dashLine
          ? '该线路是 DASH(MPD) 格式，内置播放内核不支持；请切换到其它线路'
          : '播放器打开失败：$e';
      // 走到这里可能已经过若干 async 分支，同样要防止在已销毁的 State 上 setState。
      if (seq != _openSeq || !mounted) return false;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = message;
      });
      _afterFailure(message, autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
  }

  /// 看门狗：判定「播放器只在纯顺序读、从不 seek 文件尾」就提前失败。
  ///
  /// 实测依据（2026-11-17 18:11:53，玩偶「嫁金钗」[6.0GB]E08.mkv，夸克直链）：
  ///
  /// ```
  /// 18:11:53  Range bytes=0-          → 8MB
  /// 18:11:55  Range bytes=8388608-    → +32MB
  /// 18:11:59  Range bytes=41943040-   → +32MB
  /// …         每 3~5 秒推进 32MB，25 秒共走到 209MB / 6422MB
  /// 18:12:18  打开失败 TimeoutException after 0:00:25
  /// ```
  ///
  /// mkv 的 Cues 索引在文件尾 6.42GB 处，读不到索引就没有首帧。同一部剧的
  /// mp4（1.3GB）第二个请求就是 `bytes=1398159625-`（正好文件尾），968ms 开画。
  ///
  /// 判据全部来自该样本，留足余量：≥3 条请求、走过 <20%、从未摸尾部。
  ///
  /// ★ 观察窗口从 5 秒缩到 2.5 秒（2026-11-17 20:01:24 实测依据）：
  ///   那台盘的 CDN 当时 32MB 一片只要 0.15~3.3 秒，3 条请求在 **5.3 秒**内
  ///   就凑齐了（日志 `requests=3 … elapsed=5329ms`）。判据是「≥3 条请求」，
  ///   时间只是防止刚起播就误判的下限；5 秒这个数字让每一次要换路的情况都
  ///   白等 1.7 秒。缩到 2.5 秒仍比 3 条请求的自然耗时短得多，不会误伤。
  ({Future<void> future, void Function() cancel, bool Function() fired})
  _watchSequentialOnly(String url) {
    var done = false;
    var hit = false;
    final completer = Completer<void>();
    // ★ 这里**不能**调 PlaySeekProbe.instance.reset()。
    //
    //   连点几集时多个播放器实例共存，每个实例进来都重置一次，会把别的实例
    //   刚写入的样本清掉 —— 计时永远从 0 开始，判据永远不成立。
    //   实测 2026-11-18：单独播放能正常判死（13:15 / 13:16 / 13:31），
    //   而 13:23 连续切三集时三次全部走满 25 秒超时，一次都没判死。
    //
    //   现在探针是滑动时间窗口，靠样本自身过期，不需要也不允许外部重置。
    final timer = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (done) {
        t.cancel();
        return;
      }
      final snap = PlaySeekProbe.instance;
      if (!snap.looksSequentialOnly()) {
        return;
      }
      hit = true;
      done = true;
      t.cancel();
      AppLog.w(
        'player',
        '判定为纯顺序读（从不 seek 尾部），提前放弃 ${redactUrl(url)} | $snap',
      );
      if (!completer.isCompleted) completer.complete();
    });
    return (
      future: completer.future,
      cancel: () {
        done = true;
        timer.cancel();
      },
      fired: () => hit,
    );
  }

  /// 网盘直链能初始化，但持续低速/缓冲时改用壳内 `/chunk`。
  ///
  /// 直链超时分支只在「完全打不开」时触发；这里补的是「能播但一直缓冲」：
  /// 夸克/UC/百度的部分 CDN 单连接只有 1~2 MB/s，5.2GB 的 4K mkv 会一直转圈。
  /// 采样 `PlaySpeedMeter.totalBytes`，宽限期 8 秒后连续 4 个样本里至少 3 个
  /// buffering 且 3 个低于 2.5 MB/s，才换路，避免起播/seek 被误判。
  void _watchDriveThroughput({
    required int index,
    required PlayResult target,
    required int startMs,
  }) {
    _driveSlowTimer?.cancel();
    _driveSlowEpisode = index;
    if (_driveSlowSwitchedEpisode == index ||
        !_site.isJarSpider ||
        !PlayPageUnwrap.isRangeThrottledDriveCdn(target.url)) {
      return;
    }
    AppLog.i(
      'player',
      '网盘直链开始监测下行 index=$index url=${redactUrl(target.url)}',
    );
    final started = DateTime.now();
    var lastAt = started;
    var lastBytes = PlaySpeedMeter.instance.totalBytes;
    var samples = 0;
    var stalls = 0;
    var lowSpeed = 0;

    _driveSlowTimer = Timer.periodic(
      DriveSlowSwitchPolicy.sampleInterval,
      (timer) {
        if (!mounted ||
            _index != index ||
            _driveSlowEpisode != index ||
            _error.isNotEmpty ||
            _handedToExternalPlayer) {
          timer.cancel();
          return;
        }
        final now = DateTime.now();
        if (now.difference(started) < DriveSlowSwitchPolicy.warmup) {
          lastAt = now;
          lastBytes = PlaySpeedMeter.instance.totalBytes;
          return;
        }
        final bytes = PlaySpeedMeter.instance.totalBytes;
        final elapsedMs = now.difference(lastAt).inMilliseconds;
        final speed = elapsedMs > 0
            ? (bytes - lastBytes) * 1000 / elapsedMs
            : 0.0;
        lastAt = now;
        lastBytes = bytes;
        // 暂停时不采样；buffering 时 _playing 可能仍为 true。
        if (!_playing && !_buffering) return;
        samples++;
        if (_buffering) stalls++;
        if (speed < DriveSlowSwitchPolicy.lowSpeedBytesPerSecond) lowSpeed++;
        if (DriveSlowSwitchPolicy.shouldSwitch(
          samples: samples,
          stallSamples: stalls,
          lowSpeedSamples: lowSpeed,
          isDriveCdn: true,
          isJarSpider: _site.isJarSpider,
          alreadyRetried: _driveSlowSwitchedEpisode == index,
        )) {
          timer.cancel();
          unawaited(
            _switchDriveToServe(
              index: index,
              target: target,
              startMs: startMs,
            ),
          );
        }
      },
    );
  }

  Future<void> _switchDriveToServe({
    required int index,
    required PlayResult target,
    required int startMs,
  }) async {
    if (_driveSwitchInFlight ||
        _driveSlowSwitchedEpisode == index ||
        !_site.isJarSpider ||
        !PlayPageUnwrap.isRangeThrottledDriveCdn(target.url) ||
        index < 0 ||
        index >= _episodes.length) {
      return;
    }
    _driveSwitchInFlight = true;
    _driveSlowSwitchedEpisode = index;
    _serveRetriedEpisode = index;
    _driveServePreferred.add('${_site.key}|$_flag');
    final resume = _controller?.value.position.inMilliseconds ?? startMs;
    AppLog.w(
      'player',
      '网盘直链持续低速，改用壳内取流 index=$index resume=${resume}ms '
          'url=${redactUrl(target.url)}',
    );
    _toast('网盘直链速度过慢，正在改用壳内取流');
    try {
      final again = await _app.sourceService.replayViaServe(
        site: _site,
        config: _app.config ?? const SiteConfig(),
        flag: _flag,
        rawUrl: _episodes[index].url,
      );
      if (!mounted || _index != index) return;
      if (again == null || !again.playable) {
        _driveServePreferred.remove('${_site.key}|$_flag');
        AppLog.w('player', '壳内取流未取到，保持当前直链 index=$index');
        _toast('壳内取流未取到，继续使用当前直链');
        return;
      }
      unawaited(_openEpisode(index: index, play: again, startMs: resume));
    } finally {
      _driveSwitchInFlight = false;
    }
  }

  Future<PlayResult?> _resolve(int index) async {
    if (index < 0 || index >= _episodes.length) return null;
    final app = _app;
    HymsNative.captchaHandler = (url) {
      if (!mounted) return Future.value(null);
      return showHymsCaptchaDialog(context, url);
    };
    try {
      final play = await app.sourceService.resolvePlay(
        site: _site,
        config: app.config ?? const SiteConfig(),
        flag: _flag,
        rawUrl: _episodes[index].url,
        jarReady: app.jarReady,
      );
      // 云播线路给的是 HTML 播放页（/play/<id>、/share/<hash>），先解出直链。
      return await app.unwrapPlayPage(play);
    } finally {
      HymsNative.captchaHandler = null;
    }
  }

  /// 一次播放失败后的收尾：手动播放才触发自动换线，自动尝试由外层继续。
  void _afterFailure(
    String reason, {
    required bool autoAttempt,
    int startMs = 0,
  }) {
    if (autoAttempt) return;
    if (!_app.playerSettings.autoSwitchLine) return;
    if (_ephemeral) return;
    // startMs 是这一次打开想要的起播位置；不能拿全局 _position 代替，
    // 否则「上一集播到 30 分钟、这一集取链失败」会把这一集也跳到 30 分钟。
    unawaited(_scheduleAutoSwitch(reason, startMs: startMs));
  }

  /// 当前源线路全部失败后，换到其他源的同名资源继续尝试。
  Future<void> _scheduleAutoSwitch(String reason, {int startMs = 0}) async {
    if (_autoSwitching || !mounted) return;
    if (!_app.playerSettings.autoSwitchLine || _ephemeral) return;
    _autoSwitching = true;
    final run = ++_autoRunSeq;
    final manual = _manualSeq;
    try {
      // 旧 controller 必须在下一只初始化前彻底释放；否则 fvp/libmdk 的
      // 销毁与初始化并发会把播放内核拖崩。失败时旧画面也可能还在放。
      await _disposeControllerForSwitch();
      if (!mounted || manual != _manualSeq) return;
      // 当前这条线路已经失败，先记入已尝试集合，避免下一步又切回来。
      _autoTriedAttempts.add(
        _attemptKey(_site.key, _detail.id, _flag, _episodeName),
      );
      for (final flag in nextLineCandidates(_detail.flags, _flag)) {
        if (!mounted || manual != _manualSeq) return;
        final episodes = _detail.episodeList(flag);
        final index = matchEpisodeIndex(episodes, _episodeName, _index);
        if (index < 0) continue;
        final key = _attemptKey(
          _site.key,
          _detail.id,
          flag,
          episodes[index].name,
        );
        if (!_autoTriedAttempts.add(key)) continue;
        final oldFlag = _flag;
        AppLog.i('player', '自动换线路 $oldFlag → $flag index=$index');
        _applyAutoAttempt(_site, _detail, flag, episodes, index);
        _toast('线路「$oldFlag」播放失败，正在自动切换…');
        final ok = await _openEpisode(
          index: index,
          startMs: startMs,
          allowLogin: false,
          autoAttempt: true,
        );
        if (ok) return;
      }
      await _tryOtherSources(reason: reason, startMs: startMs, manual: manual);
    } finally {
      if (run == _autoRunSeq) _autoSwitching = false;
    }
  }

  /// 当前源没有可用线路时，搜索其他源里同名（优先同年）的资源。
  Future<void> _tryOtherSources({
    required String reason,
    required int startMs,
    required int manual,
  }) async {
    if (!mounted || manual != _manualSeq) return;
    setState(() {
      _resolving = true;
      _buffering = true;
      _error = '';
    });
    _toast('本源线路不可用，正在搜索其他源的《${_detail.name}》…');
    // 资源名常带「《…》动漫高清完整版在线观看」这类后缀，直接拿去搜索
    // 和比对会找不到同名资源；先归一成剧名再搜索。
    final searchTitle = ArtworkService.dramaTitle(_detail.name).trim();
    final keyword = searchTitle.isEmpty ? _detail.name : searchTitle;
    AppLog.i('player', '自动换源搜索 $keyword（资源名 ${_detail.name}）');
    final app = _app;
    final filter = app.contentFilter;
    final sites = filter.active
        ? app.usableSites.where((s) => !filter.blocksSource(s)).toList()
        : app.usableSites;
    final stream = app.searchService.search(keyword, sites);
    final fetched = <String, List<VodItem>>{};
    final done = _autoSearchDone = Completer<void>();
    final sub = _autoSearchSub = stream.listen(
      (progress) {
        fetched.clear();
        fetched.addAll(progress.sourceItems);
        if (progress.finished && !done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    _autoSearchTimer = Timer(const Duration(seconds: 60), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    _autoSearchTimer?.cancel();
    _autoSearchTimer = null;
    try {
      await sub.cancel();
    } catch (_) {}
    if (identical(_autoSearchSub, sub)) _autoSearchSub = null;
    if (identical(_autoSearchDone, done)) _autoSearchDone = null;
    if (!mounted || manual != _manualSeq) return;

    final targetTitle = titleSignature(ArtworkService.dramaTitle(_detail.name));
    final targetYear = _detail.year.trim();
    final candidates = <({SourceBean site, VodItem item})>[];
    final seen = <String>{};
    for (final entry in fetched.entries) {
      if (entry.key == _site.key || _autoTriedSources.contains(entry.key)) {
        continue;
      }
      final site = _siteByKey(entry.key);
      if (site == null || !app.isSiteUsable(site)) continue;
      for (final item in entry.value) {
        if (titleSignature(ArtworkService.dramaTitle(item.name)) !=
            targetTitle) {
          continue;
        }
        if (item.id.trim().isEmpty) continue;
        if (!seen.add('${site.key}|${item.id}')) continue;
        candidates.add((site: site, item: item));
      }
    }
    candidates.sort((a, b) {
      final ay = targetYear.isNotEmpty && a.item.year.trim() == targetYear
          ? 0
          : 1;
      final by = targetYear.isNotEmpty && b.item.year.trim() == targetYear
          ? 0
          : 1;
      if (ay != by) return ay - by;
      final an = a.item.name == _detail.name ? 0 : 1;
      final bn = b.item.name == _detail.name ? 0 : 1;
      return an - bn;
    });
    if (candidates.isEmpty) {
      _autoFail('没有找到其他源的相同片名：$reason');
      return;
    }

    final episodeName = _episodeName;
    final fallbackIndex = _index;
    for (final candidate in candidates) {
      if (!mounted || manual != _manualSeq) return;
      _autoTriedSources.add(candidate.site.key);
      VodDetail? detail;
      try {
        // 自动换源同样优先于后台搜索：先释放搜索占用的 JAR host。
        app.searchService.cancelActiveRound();
        detail = await app.sourceService.detail(
          candidate.site,
          candidate.item.id,
          name: candidate.item.name,
        );
      } catch (e) {
        AppLog.w('player', '自动换源详情失败 ${candidate.site.key} $e');
      }
      if (!mounted || manual != _manualSeq) return;
      if (detail == null || detail.episodes.isEmpty) continue;
      if (titleSignature(ArtworkService.dramaTitle(detail.name)) !=
          targetTitle) {
        continue;
      }
      // 同名但类型不同（单集电影 ↔ 多集剧集）：不要拿电影去配剧集第 1 集。
      if (_episodes.length == 1 &&
          detail.episodes.values.any((list) => list.length > 1)) {
        continue;
      }
      final detailFlags = detail.flags.isEmpty ? const [''] : detail.flags;
      for (final flag in detailFlags) {
        if (!mounted || manual != _manualSeq) return;
        final episodes = detail.episodeList(flag);
        final index = matchEpisodeIndex(episodes, episodeName, fallbackIndex);
        if (index < 0) continue;
        final key = _attemptKey(
          candidate.site.key,
          detail.id,
          flag,
          episodes[index].name,
        );
        if (!_autoTriedAttempts.add(key)) continue;
        AppLog.i('player', '自动换源 ${candidate.site.key} · $flag index=$index');
        _applyAutoAttempt(candidate.site, detail, flag, episodes, index);
        _toast('已切换到其他源「${candidate.site.displayName}」·「$flag」');
        final ok = await _openEpisode(
          index: index,
          startMs: startMs,
          allowLogin: false,
          autoAttempt: true,
        );
        if (ok) return;
      }
    }
    _autoFail(_error.isNotEmpty ? '所有线路和其他源都失败：$_error' : '所有线路和其他源都失败');
  }

  Future<void> _disposeControllerForSwitch() async {
    // 自动换线同理：旧线路的转发会话必须先掐掉，否则它会继续占着带宽。
    LocalRelay.instance.releasePlaySessions();
    // 换线路就是换片：探针窗口同样要清，理由见 _openEpisode 里的说明。
    PlaySeekProbe.instance.reset();
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerValue);
    final future = old?.dispose();
    if (future == null) return;
    _controllerDisposePending = future;
    try {
      // 自动换线也一样：prepare 卡住时 dispose 不会返回，最多等 5 秒。
      await future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // 释放失败不影响下一只初始化
    } finally {
      if (identical(_controllerDisposePending, future)) {
        _controllerDisposePending = null;
      }
    }
  }

  void _applyAutoAttempt(
    SourceBean site,
    VodDetail detail,
    String flag,
    List<Episode> episodes,
    int index,
  ) {
    if (!mounted) return;
    setState(() {
      _site = site;
      _detail = detail;
      _flag = flag;
      _episodes = episodes;
      _index = index;
      _driveSlowSwitchedEpisode = -1;
      _resolving = true;
      _buffering = true;
      _playing = false;
      _error = '';
      _autoErrorHandled = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _subtitleStatus = '';
      _danmaku = const [];
      _allDanmaku = const [];
      _danmakuSeq++;
      _audioOptions = const [];
      _activeAudio = null;
      _errorLogged = false;
      _mediaStats = null;
      _netSmoother.reset();
      _live = false;
    });
  }

  void _autoFail(String message) {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _buffering = false;
      _error = message;
    });
    _toast(message);
  }

  String _attemptKey(
    String siteKey,
    String detailId,
    String flag,
    String episodeName,
  ) => '$siteKey|$detailId|$flag|${episodeSignature(episodeName)}';

  SourceBean? _siteByKey(String key) {
    for (final site in _app.config?.sites ?? const <SourceBean>[]) {
      if (site.key == key) return site;
    }
    return null;
  }

  /// 打开睡眠定时器弹层并应用选择。
  Future<void> _openSleepTimer() async {
    final choice = await showSleepTimerSheet(
      context: context,
      current: _sleepTimer.state,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (choice == null || !mounted) return;
    if (choice.cancel) {
      _sleepTimer.cancel();
      _toast('已关闭睡眠定时');
      return;
    }
    if (choice.atEndOfVideo) {
      _sleepTimer.startAtEndOfVideo();
      _toast('这一集播完后暂停，不会自动连播');
      return;
    }
    final duration = choice.duration;
    if (duration != null) {
      _sleepTimer.startForDuration(duration);
      _toast('${SleepTimer.formatDuration(duration.inMilliseconds)} 后自动暂停');
    }
  }

  void _onCompleted() {
    if (_live) return;
    // 睡眠定时器优先于自动连播：「播完当前视频后暂停」就是让这一集播完后停下，
    // 不能被下面的自动连播逻辑抢先切到下一集。
    if (_sleepTimer.handleVideoEnded()) {
      _controller?.pause();
      _toast('已播完，睡眠定时器已暂停播放');
      return;
    }
    if (_outroFired) return; // 片尾跳过已经接管了切集
    final app = _app;
    if (!app.playerSettings.autoPlayNext) return;
    if (_index + 1 < _episodes.length) {
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _switchTo(_index + 1);
      });
    }
  }

  Future<void> _switchTo(int index, {bool allowLogin = true}) {
    // 取链 / 打开过程中忽略换集点击，避免并发打开多份。
    if (_resolving) return Future<void>.value();
    if (index != _index) {
      // 新的一集重新开始自动换线记录，避免上一集的失败源被误跳过。
      _autoTriedAttempts.clear();
      _autoTriedSources.clear();
    }
    return _openEpisode(index: index, allowLogin: allowLogin);
  }

  /// 选集面板里手动换线路：线路和选集一起切换，再打开对应线路的这一集。
  Future<void> _switchLine(String flag, int index) async {
    if (_resolving) return;
    if (flag == _flag) {
      if (index != _index) await _switchTo(index);
      return;
    }
    final episodes = _detail.episodeList(flag);
    if (index < 0 || index >= episodes.length) return;
    setState(() {
      _flag = flag;
      _episodes = episodes;
      _index = index;
      _error = '';
      _directRetriedEpisode = -1;
      _mediaRetriedEpisode = -1;
      _serveRetriedEpisode = -1;
      _driveSlowSwitchedEpisode = -1;
    });
    _toast('已切换到线路「${flag.isEmpty ? '默认线路' : flag}」');
    await _openEpisode(index: index);
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
  }



  Future<void> _saveProgress() async {
    if (_live) return;
    final app = _app;
    if (_ephemeral) return;
    if (!app.playerSettings.rememberProgress) return;
    if (_duration.inMilliseconds <= 0) return;
    final key = '${_detail.sourceKey}|${_detail.id}';
    await app.updateHistoryProgress(
      key,
      _position.inMilliseconds,
      _duration.inMilliseconds,
    );
  }

  void _showControls() {
    if (!mounted) return;
    setState(() {
      _controls = true;
      _cursorVisible = true;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) {
        setState(() {
          _controls = false;
          _cursorVisible = false;
        });
      }
    });
  }

  /// 鼠标移动**不再**唤出控制栏（控制栏改为单击唤出）。
  ///
  /// 只负责光标：控制栏收起时光标也跟着隐藏，此时移动鼠标必须能看见指针，
  /// 否则用户既看不到控制栏、也看不到自己在点哪里。静止 3 秒后再收起。
  void _onPointerMove() {
    if (!mounted || _controls) return;
    if (!_cursorVisible) setState(() => _cursorVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_controls) setState(() => _cursorVisible = false);
    });
  }

  /// 缓冲提示：短暂缓冲（不到 350ms）不亮转圈。
  ///
  /// 最大缓冲偏小时，每个分片交界处都可能出现一次很短的 buffering；
  /// 立刻盖一层转圈会让本来只是轻微补帧的播放看起来「一卡一卡」。
  void _syncBufferingHint(bool buffering) {
    if (buffering) {
      if (_bufferingHint || _bufferingHintTimer != null) return;
      _bufferingHintTimer = Timer(const Duration(milliseconds: 350), () {
        _bufferingHintTimer = null;
        if (!mounted || !_buffering) return;
        setState(() => _bufferingHint = true);
      });
    } else {
      _bufferingHintTimer?.cancel();
      _bufferingHintTimer = null;
      if (_bufferingHint) setState(() => _bufferingHint = false);
    }
  }

  /// 播放中阻止系统自动休眠 / 关屏；暂停、出错时立即恢复系统策略。
  void _syncSleepInhibitor() {
    final active = _error.isEmpty && (_playing || _buffering);
    if (active && !_sleepHeld) {
      _sleepHeld = true;
      SleepInhibitor.acquire();
    } else if (!active && _sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.release();
    }
  }

  /// 单击画面：控制栏在「显示」与「收缩」之间切换。
  ///
  /// 与双击全屏不冲突：两者挂在同一个 GestureDetector 上，Flutter 的手势
  /// 仲裁会等双击判定窗口过去再决定是否派发 onTap —— 快速双击只会进入全屏，
  /// 不会顺带把控制栏切一下。
  void _toggleControls() {
    if (!mounted) return;
    if (_controls) {
      // 收缩：光标一起收，并取消待执行的自动收设计时器，
      // 否则下次唤出后旧的计时器可能立刻把控制栏又收掉。
      _hideTimer?.cancel();
      setState(() {
        _controls = false;
        _cursorVisible = false;
      });
    } else {
      _showControls();
    }
  }

  /// 长按画面：临时 1.5x（松开恢复原倍速）。
  Future<void> _startHoldRate() async {
    if (_holdingRate || _controller == null) return;
    _holdingRate = true;
    _rateBeforeHold = _rate;
    final boost = _rate < 1.5 ? 1.5 : _rate;
    setState(() => _rate = boost);
    await _controller?.setPlaybackSpeed(boost);
    if (boost != _rateBeforeHold) _toast('长按 1.5x 快进中');
  }

  Future<void> _endHoldRate() async {
    if (!_holdingRate) return;
    _holdingRate = false;
    final back = _rateBeforeHold ?? _app.playerSettings.speed;
    _rateBeforeHold = null;
    if (mounted) setState(() => _rate = back);
    await _controller?.setPlaybackSpeed(back);
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    _showControls();
  }

  /// 老板键：暂停当前视频；返回是否真的从播放中暂停（原本暂停就不恢复）。
  bool _pauseForBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return false;
    if (!controller.value.isPlaying) return false;
    controller.pause();
    return true;
  }

  /// 老板键恢复：只有按下前正在播放时才继续播放。
  void _resumeFromBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isPlaying) controller.play();
  }

  void _seekBy(Duration delta) {
    if (_live) return;
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    controller.seekTo(target);
  }

  void _seekTo(Duration target) {
    if (_live) return;
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    var safe = target;
    if (safe < Duration.zero) safe = Duration.zero;
    if (total > Duration.zero && safe > total) safe = total;
    controller.seekTo(safe);
  }

  /// 手机全屏横向滑动：按屏幕宽度映射成进度，松手才真正 seek。
  ///
  /// 手指在画面任意位置左右滑都能用，符合安卓播放器的操作习惯；
  /// 拖动过程中只更新预览 HUD，避免每一帧都向内核发 seek。
  void _onSeekDragStart(DragStartDetails details) {
    if (!_isMobile || _live) return;
    if (_duration <= Duration.zero) return;
    _seekDragBase = _position;
    setState(() => _seekDragTarget = _position);
  }

  void _onSeekDragUpdate(DragUpdateDetails details) {
    final target = _seekDragTarget;
    if (target == null) return;
    final totalMs = _duration.inMilliseconds;
    if (totalMs <= 0) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final deltaMs =
        (details.primaryDelta ?? 0) / width * totalMs;
    var next = target + Duration(milliseconds: deltaMs.round());
    if (next < Duration.zero) next = Duration.zero;
    if (next > _duration) next = _duration;
    setState(() => _seekDragTarget = next);
  }

  void _onSeekDragEnd(DragEndDetails details) {
    final target = _seekDragTarget;
    if (target == null) return;
    setState(() => _seekDragTarget = null);
    _seekTo(target);
  }

  void _onSeekDragCancel() {
    if (_seekDragTarget == null) return;
    setState(() => _seekDragTarget = null);
  }

  /// 横向滑动进度的预览浮层：目标时间 + 相对起点的快进 / 快退量。
  Widget _seekDragHud() {
    final target = _seekDragTarget;
    if (target == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final diff = target - _seekDragBase;
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.74),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      diff.isNegative
                          ? Icons.fast_rewind_rounded
                          : Icons.fast_forward_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_fmt(target)} / ${_fmt(_duration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${diff.isNegative ? '-' : '+'}${_fmt(diff.abs())}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _syncAndroidDeviceState() async {
    if (!_isAndroid) return;
    try {
      final brightness = await _androidDeviceChannel.invokeMethod<double>(
        'getScreenBrightness',
      );
      final volume = await _androidDeviceChannel.invokeMethod<double>(
        'getSystemVolume',
      );
      if (!mounted) return;
      setState(() {
        if (brightness != null) {
          _androidBrightness = brightness.clamp(0.0, 1.0);
        }
        if (volume != null) {
          _androidSystemVolume = volume.clamp(0.0, 1.0);
        }
      });
    } catch (_) {}
  }

  Future<void> _applyAndroidOrientation({
    required bool portrait,
    bool manual = false,
  }) async {
    if (!_isAndroid) return;
    if (manual) {
      _manualOrientationLocked = true;
    }
    if (mounted) {
      setState(() {
        _portraitFullscreen = portrait;
      });
    } else {
      _portraitFullscreen = portrait;
    }
    _landscapeUiApplied = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(
      portrait
          ? const [
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (!_isAndroid) return;
    final size = MediaQuery.of(context).size;
    final dy = details.globalPosition.dy;
    if (dy < 48 || dy > size.height - 48) {
      _verticalDragMode = null;
      return;
    }
    _verticalDragMode =
        details.globalPosition.dx < size.width / 2 ? 'brightness' : 'volume';
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isAndroid || _verticalDragMode == null) return;
    final height = MediaQuery.of(context).size.height;
    if (height <= 0) return;
    final delta = -details.delta.dy / (height * 0.65);
    if (_verticalDragMode == 'brightness') {
      _androidBrightness = (_androidBrightness + delta).clamp(0.0, 1.0);
      _brightnessOverridden = true;
      unawaited(
        _androidDeviceChannel.invokeMethod<void>(
          'setScreenBrightness',
          _androidBrightness,
        ),
      );
      _showGestureHud(
        icon: _androidBrightness < 0.35
            ? Icons.brightness_low_rounded
            : (_androidBrightness < 0.7
                ? Icons.brightness_medium_rounded
                : Icons.brightness_high_rounded),
        label: '亮度',
        progress: _androidBrightness,
      );
    } else if (_verticalDragMode == 'volume') {
      _androidSystemVolume = (_androidSystemVolume + delta).clamp(0.0, 1.0);
      unawaited(
        _androidDeviceChannel.invokeMethod<void>(
          'setSystemVolume',
          _androidSystemVolume,
        ),
      );
      _showGestureHud(
        icon: _androidSystemVolume <= 0.001
            ? Icons.volume_off_rounded
            : (_androidSystemVolume < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded),
        label: '音量',
        progress: _androidSystemVolume,
      );
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) => _finishVerticalDrag();

  void _onVerticalDragCancel() => _finishVerticalDrag();

  void _finishVerticalDrag() {
    _verticalDragMode = null;
  }

  void _showGestureHud({
    required IconData icon,
    required String label,
    required double progress,
  }) {
    _gestureHudTimer?.cancel();
    if (mounted) {
      setState(() {
        _gestureHudVisible = true;
        _gestureHudIcon = icon;
        _gestureHudLabel = label;
        _gestureHudProgress = progress.clamp(0.0, 1.0);
      });
    }
    _gestureHudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _gestureHudVisible = false;
        });
      }
    });
  }

  Widget _androidGestureHud() {
    if (!_isAndroid || !_gestureHudVisible) {
      return const SizedBox.shrink();
    }
    final pct = (_gestureHudProgress * 100).round();
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 180,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_gestureHudIcon, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    '$_gestureHudLabel $pct%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _gestureHudProgress,
                  minHeight: 5,
                  backgroundColor: Colors.white.withValues(alpha: 0.24),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _volumeIcon {
    if (_volume <= 0.001) return Icons.volume_off_rounded;
    if (_volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  /// 调播放器自己的音量（0–1），`persist` 为 true 时写入播放设置。
  Future<void> _setVolume(double value, {bool persist = false}) async {
    final volume = value.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    if (mounted) setState(() => _volume = volume);
    await _controller?.setVolume(volume);
    if (!persist) return;
    final app = _app;
    await app.setPlayerSettings(app.playerSettings.copyWith(volume: volume));
  }

  /// 鼠标滚轮：向上加音量，向下减音量（每次一格 5%，与 ↑/↓ 一致）。
  void _onWheelVolume(double dy) {
    if (dy == 0) return;
    unawaited(_setVolume(_volume + (dy < 0 ? 0.05 : -0.05)));
    _flashVolumeHud();
    _showControls();
    _volumeWheelTimer?.cancel();
    _volumeWheelTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      unawaited(_setVolume(_volume, persist: true));
    });
  }

  /// 音量提示：每次调整重置计时，停手 1.2 秒后自动收起。
  void _flashVolumeHud() {
    if (!mounted) return;
    setState(() => _volumeHudVisible = true);
    _volumeHudTimer?.cancel();
    _volumeHudTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeHudVisible = false);
    });
  }

  void _toggleMute() {
    if (_volume > 0.001) {
      unawaited(_setVolume(0, persist: true));
    } else {
      unawaited(
        _setVolume(_lastVolume <= 0.001 ? 1 : _lastVolume, persist: true),
      );
    }
  }

  Future<void> _showVolume() => showVolumeSheet(
    context: context,
    volume: _volume,
    onChanged: (v) => _setVolume(v),
    onCommit: (v) => _setVolume(v, persist: true),
    onToggleMute: _toggleMute,
    hint: '↑ / ↓ 以 5% 步进调节，M 静音；播放器音量与 Windows 系统音量互不影响。',
  );

  Future<void> _toggleFullscreen() async {
    // 小窗也允许全屏：进入全屏后临时铺满屏幕，退出全屏时窗口恢复成原来的
    // 小窗尺寸，`_mini` 状态保持不变。
    if (_fsToggling) return;
    _fsToggling = true;
    final next = !_fullscreen;
    try {
      // 先把过渡动画归零，窗口切换后的第一帧就从缩放/半透明状态开始，
      // 不再出现「先满帧闪一下、再开始动画」的突兀感。
      setState(() {
        _fullscreen = next;
        _fsAnim.value = 0;
      });
      if (_isMobile) {
        await SystemChrome.setEnabledSystemUIMode(
          next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } else {
        await setWindowFullscreen(next);
      }
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      // 纯 Flutter 合成层动画：不触发逐帧窗口 resize，不会卡顿。
      _fsAnim.forward();
    } finally {
      _fsToggling = false;
    }
  }

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isDesktop => !kIsWeb && !_isMobile;

  Future<void> _toggleAlwaysOnTop() async {
    if (!_isDesktop) return;
    final next = !_alwaysOnTop;
    setState(() => _alwaysOnTop = next);
    await setAppWindowAlwaysOnTop(next);
    if (mounted) _toast(next ? '窗口已置顶（仅本次播放生效）' : '已取消窗口置顶');
  }

  Future<void> _toggleMini() => _setMini(!_mini);

  /// 展开 / 收起小窗；[announce] 只在用户手动切换时提示。
  Future<void> _setMini(bool next, {bool announce = true}) async {
    if (!_isDesktop || next == _mini) return;
    if (next && _fullscreen) await _toggleFullscreen();
    if (next) {
      _pinnedBeforeMini = _alwaysOnTop;
      await enterMiniPlayerWindow();
    } else {
      await exitMiniPlayerWindow();
    }
    if (!mounted) return;
    setState(() {
      _mini = next;
      if (next) {
        // 小窗本身始终置顶；顶栏图钉同步为「已置顶」，可在小窗里手动取消。
        _alwaysOnTop = true;
        _controls = false;
      } else {
        _alwaysOnTop = _pinnedBeforeMini;
      }
    });
    // exitMiniPlayerWindow 会把置顶关掉，这里恢复退出小窗后的选择。
    if (!next) await setAppWindowAlwaysOnTop(_alwaysOnTop);
    if (next && announce) _toast('小窗模式：窗口已置顶，点画面显示控制');
  }

  Future<void> _exitPage() async {
    // 独立窗口关闭后主窗口会重新读盘，先把最后进度落下来。
    try {
      await _saveProgress();
    } catch (_) {}
    final exit = widget.onExit;
    if (exit != null) {
      await exit();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _requestExit() => unawaited(_exitPage());

  @override
  void dispose() {
    // 离开播放器即作废睡眠定时器：它的作用域就是这一集，不该在后台继续倒计时。
    _sleepTimer.dispose();
    _bufferingHintTimer?.cancel();
    _gestureHudTimer?.cancel();
    if (_isAndroid && _brightnessOverridden) {
      unawaited(
        _androidDeviceChannel.invokeMethod<void>('setScreenBrightness', -1.0),
      );
    }
    BossKeyService.instance.unbindPlayer(this);
    // 一起看：房主关掉播放器就散场；观众停止轮询。
    if (_partyBound) {
      _app.watchParty.removeListener(_onPartyUpdate);
      if (_app.watchParty.active) _app.watchParty.leave();
      _partyBound = false;
    }
    if (_opened) _saveProgress();
    // 网盘取流地址指向常驻 JVM 自己的内存服务，离开播放器就回收该进程。
    // 但地址已交给外部播放器时不能回收：Yaozhi MPV / PotPlayer 还在读 /chunk。
    if (_opened && !_handedToExternalPlayer) {
      unawaited(_app.sourceService.jar.stopPlayback());
    }
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _detailsTimer?.cancel();
    _driveSlowTimer?.cancel();
    _driveSlowTimer = null;
    _cancelPendingSkipPick();
    final autoSearchDone = _autoSearchDone;
    if (autoSearchDone != null && !autoSearchDone.isCompleted) {
      autoSearchDone.complete();
    }
    final autoSearchSub = _autoSearchSub;
    if (autoSearchSub != null) unawaited(autoSearchSub.cancel());
    _autoSearchSub = null;
    _autoSearchTimer?.cancel();
    _autoSearchTimer = null;
    if (_sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.releaseAll();
    }
    if (_mini) unawaited(exitMiniPlayerWindow());
    // 置顶只在本次播放会话内有效：离开播放器时无论如何都复位。
    unawaited(setAppWindowAlwaysOnTop(false));
    _volumeWheelTimer?.cancel();
    _volumeHudTimer?.cancel();
    _fsAnim.dispose();
    _controller?.removeListener(_onPlayerValue);
    _controller?.dispose();
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    // 沉浸观影模式下回到外壳仍要保持全屏，不能把系统栏放出来。
    final keepImmersive =
        _immersiveMode &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android;
    if (_fullscreen && isDesktop && !_immersiveMode) {
      setWindowFullscreen(false);
    } else if (_fullscreen && !isDesktop) {
      SystemChrome.setEnabledSystemUIMode(
        keepImmersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } else if (_landscapeUiApplied && !isDesktop) {
      // 自动横屏隐藏了系统栏，离开播放器恢复（与全屏恢复一致）。
      SystemChrome.setEnabledSystemUIMode(
        keepImmersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    // 移动端自动横屏：离开播放器时恢复系统默认方向。
    // 沉浸观影模式下保持横屏，否则回到大屏外壳会立刻竖屏闪一下。
    if (_opened && _isMobile) {
      if (_immersiveMode &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android) {
        unawaited(
          SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]),
        );
      } else {
        unawaited(
          SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
        );
      }
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -10));
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 10));
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_setVolume(_volume + 0.05, persist: true));
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_setVolume(_volume - 0.05, persist: true));
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    // F / Enter 都切换全屏：Enter 是遥控器与客厅键盘上最顺手的那个键。
    if (key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        _requestExit();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.f1) {
      unawaited(showPlayerKeyHelp(context, live: false));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 播放失败时按片名回主界面做一次全源搜索，方便直接换到其他源。
  void _switchSource() {
    final name = _detail.name.trim();
    if (name.isEmpty) {
      _toast('没有可搜索的片名');
      return;
    }
    final remote = widget.onSwitchSource;
    if (remote != null) {
      unawaited(remote(name));
      return;
    }
    AppScope.of(context).requestSearch(name);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// part 里的 extension 不能直接调用 @protected 的 setState，统一走这里。
  void _setState(VoidCallback fn) => setState(fn);

  void _toast(String message) {
    if (!mounted) return;
    // 播放器底栏是自绘的：默认 fixed SnackBar 会压在进度条和播放键上。
    // 改成悬浮提示，并抬高到底栏上方，效果接近 Android Toast。
    const bottomGap = 150.0;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final gap = (bottomGap + MediaQuery.paddingOf(context).bottom)
        .clamp(24.0, screenHeight * 0.5)
        .toDouble();
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black.withValues(alpha: 0.86),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.fromLTRB(24, 0, 24, gap),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 悬浮层的进度格式：`1:08` / `30:00` / `1:02:00`（分钟不补零）。
  String _fmtOverlay(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  void _toggleDetails() {
    setState(() => _detailsVisible = !_detailsVisible);
    _startDetailsTimer();
    if (_detailsVisible) _showControls();
    // 记忆开关状态：下次打开播放器沿用这次的选择。
    unawaited(
      _app.setPlayerSettings(
        _app.playerSettings.copyWith(overlayVisible: _detailsVisible),
      ),
    );
  }

  /// 时钟、码率、缓冲这些不是播放器回调驱动，靠每秒重绘。
  void _startDetailsTimer() {
    _detailsTimer?.cancel();
    _detailsTimer = null;
    if (!_detailsVisible) {
      _mediaStats = null;
      _netSmoother.reset();
      _live = false;
      return;
    }
    _updateDetailsStats();
    _detailsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDetailsStats();
      if (mounted) setState(() {});
    });
  }

  /// 每秒采样一次 fvp MediaInfo，并更新平滑后的网速展示值。
  void _updateDetailsStats() {
    final stats = _readMediaStats();
    _mediaStats = stats;
    _netSmoother.add(stats?.bitRate ?? 0);
  }

  /// 刷新播放（主流播放器行为）：按当前进度重新取链、重建播放器。
  Future<void> _refreshPlayback() async {
    if (_refreshing || _resolving) return;
    final posMs = _position.inMilliseconds;
    _refreshing = true;
    if (mounted) setState(() {});
    _toast('正在刷新播放地址…');
    try {
      await _openEpisode(index: _index, startMs: posMs > 2000 ? posMs : 0);
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  /// 长按「详情」：勾选要显示的指标、调整字号，保存到播放设置。
  Future<void> _showDetailsSettings() async {
    final app = _app;
    final result = await showPlayerOverlaySettings(
      context: context,
      title: '播放详情显示',
      metrics: kPlayerOverlayMetrics,
      defaultMetrics: kDefaultPlayerOverlayMetrics,
      selectedMetrics: app.playerSettings.overlayMetrics,
      fontSize: app.playerSettings.overlayFontSize,
    );
    if (result == null) return;
    await app.setPlayerSettings(
      app.playerSettings.copyWith(
        overlayMetrics: result.metrics,
        overlayFontSize: result.fontSize,
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _detailsOverlay(BuildContext context) {
    final settings = _app.playerSettings;
    final fontSize = settings.overlayFontSize.clamp(10.0, 28.0).toDouble();
    final enabled = settings.overlayMetrics.toSet();
    final media = _mediaStats;
    final topLeft = _cornerLines('tl', enabled, fontSize, media);
    final topRight = _cornerLines('tr', enabled, fontSize, media);
    final bottomLeft = _cornerLines('bl', enabled, fontSize, media);
    final bottomRight = _cornerLines('br', enabled, fontSize, media);
    if (topLeft.isEmpty &&
        topRight.isEmpty &&
        bottomLeft.isEmpty &&
        bottomRight.isEmpty) {
      return const SizedBox.shrink();
    }
    final padding = EdgeInsets.fromLTRB(
      18,
      MediaQuery.paddingOf(context).top + (_controls ? 62 : 16),
      18,
      MediaQuery.paddingOf(context).bottom + (_controls ? 108 : 16),
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          padding: padding,
          child: Stack(
            children: [
              if (topLeft.isNotEmpty)
                Align(
                  alignment: Alignment.topLeft,
                  child: _overlayColumn(topLeft),
                ),
              if (topRight.isNotEmpty)
                Align(
                  alignment: Alignment.topRight,
                  child: _overlayColumn(topRight, end: true),
                ),
              if (bottomLeft.isNotEmpty)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: _overlayColumn(bottomLeft),
                ),
              if (bottomRight.isNotEmpty)
                Align(
                  alignment: Alignment.bottomRight,
                  child: _overlayColumn(bottomRight, end: true),
                ),
            ],
          ),
        ),
      ),
    );
  }


  Widget _overlayColumn(List<Widget> lines, {bool end = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: lines,
    );
  }

  List<Widget> _cornerLines(
    String corner,
    Set<String> enabled,
    double fontSize,
    _MediaStats? media,
  ) {
    final lines = <Widget>[];
    for (final metric in kPlayerOverlayMetrics) {
      if (metric.corner != corner || !enabled.contains(metric.id)) continue;
      final text = _metricText(metric.id, media);
      if (text == null || text.isEmpty) continue;
      final title = metric.id == 'title';
      lines.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: title ? fontSize + 4 : fontSize,
              fontWeight: title ? FontWeight.w700 : FontWeight.w500,
              height: 1.25,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
            ),
          ),
        ),
      );
    }
    return lines;
  }

  String? _metricText(String id, _MediaStats? media) {
    final value = _controller?.value;
    switch (id) {
      case 'title':
        return _detail.name;
      case 'episode':
        if (_live) return '直播';
        return _episodeName.isEmpty ? '${_index + 1}集' : _episodeName;
      case 'resolution':
        final w = media?.width ?? value?.size.width.round() ?? 0;
        final h = media?.height ?? value?.size.height.round() ?? 0;
        return w > 0 && h > 0 ? '$w×$h' : null;
      case 'fps':
        final fps = media?.fps ?? 0;
        return fps > 0
            ? '${fps.toStringAsFixed(fps % 1 == 0 ? 0 : 2)} fps'
            : null;
      case 'codec':
        final codec = media?.videoCodec ?? '';
        return codec.isEmpty ? null : codec;
      case 'format':
        final format = media?.format ?? '';
        return format.isEmpty ? null : format;
      case 'source':
        return _site.displayName;
      case 'line':
        return _flag;
      case 'clock':
        final now = DateTime.now();
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        final s = now.second.toString().padLeft(2, '0');
        return '$h:$m:$s';
      case 'progress':
        if (_live) return null;
        return _duration.inMilliseconds > 0
            ? '${_fmtOverlay(_position)}/${_fmtOverlay(_duration)}'
            : null;
      case 'remaining':
        if (_live || _duration.inMilliseconds <= 0) return null;
        final left = _duration - _position;
        return left.isNegative ? null : '-${_fmtOverlay(left)}';
      case 'net':
        // ★ 数据源改成中继的真实转发字节，**显示格式保持原版不变**。
        //
        //   原版读的是 fvp 的 `MediaInfo.bitRate`，那是容器里写的标称码率：
        //   奥德赛 82.2G 那条 Remux 读出来是 0，右下角就一直空着。中继 `/play`
        //   是播放数据的必经之路，在那里数字节才是真正的下行速率。
        //   格式与原版逐字一致（`12.3 Mb/s` / `860 kb/s`），只换数据源；
        //   只有没走中继的线路（fvp 直连）才退回标称码率。
        final relayBytes = PlaySpeedMeter.instance.bytesPerSecond;
        final bits = relayBytes > 0
            ? relayBytes * 8.0
            : _netSmoother.value.toDouble();
        if (bits <= 0) return null;
        return bits >= 1000000
            ? '${(bits / 1000000).toStringAsFixed(1)} Mb/s'
            : '${(bits / 1000).round()} kb/s';
      case 'buffer':
        if (_live) return null;
        final ahead = _bufferedAhead(value);
        return ahead == null ? null : '缓冲 ${ahead.toStringAsFixed(1)}s';
      case 'audio':
        final codec = media?.audioCodec ?? '';
        if (codec.isEmpty) return null;
        final channels = media?.audioChannels ?? 0;
        return channels > 0 ? '$codec ${channels}ch' : codec;
      case 'volume':
        return value == null ? null : '音量 ${(value.volume * 100).round()}%';
      case 'rate':
        return '${_rate.toStringAsFixed(_rate % 1 == 0 ? 0 : 2)}x';
    }
    return null;
  }

  double? _bufferedAhead(VideoPlayerValue? value) {
    if (value == null || value.buffered.isEmpty) return null;
    var end = Duration.zero;
    for (final range in value.buffered) {
      if (range.end > end) end = range.end;
    }
    final ahead = end - value.position;
    return ahead.inMilliseconds <= 0 ? null : ahead.inMilliseconds / 1000;
  }

  /// 已缓冲到的位置（毫秒）：取所有 buffered range 里最靠后的 end。
  double _bufferedEndMs() {
    final value = _controller?.value;
    if (value == null || value.buffered.isEmpty) return 0;
    var end = Duration.zero;
    for (final range in value.buffered) {
      if (range.end > end) end = range.end;
    }
    return end.inMilliseconds.toDouble();
  }

  /// 把设置里的「起播预缓冲 / 最大缓冲」写进 fvp（libmdk）内核。
  ///
  /// video_player 没有等价参数，非 fvp 内核时直接跳过。换集时调用一次；
  /// 设置变更由 didChangeDependencies 触发重新下发，当前集立即生效。
  void _applyBufferRange(VideoPlayerController controller) {
    if (!_mdkEnabled) return;
    final settings = _app.playerSettings;
    final minMs = (settings.bufferMinSec * 1000)
        .round()
        .clamp(200, 30000)
        .toInt();
    final maxMs = (settings.bufferMaxSec * 1000)
        .round()
        .clamp(minMs + 500, 120000)
        .toInt();
    try {
      controller.setBufferRange(min: minMs, max: maxMs);
    } catch (_) {
      // 内核未接管时扩展会抛 StateError，退化为内核默认缓冲
    }
  }

  /// 读 fvp 的 MediaInfo：分辨率、帧率、编码、容器与实时码率（当作网速）。
  ///
  /// fvp 未接管时扩展会抛 StateError，读不到就退化为 VideoPlayerValue。
  _MediaStats? _readMediaStats() {
    if (!_mdkEnabled) return null;
    final controller = _controller;
    if (controller == null) return null;
    try {
      final info = controller.getMediaInfo();
      if (info == null) return null;
      final video = (info.video?.isNotEmpty ?? false)
          ? info.video!.first
          : null;
      final audio = (info.audio?.isNotEmpty ?? false)
          ? info.audio!.first
          : null;
      return _MediaStats(
        width: video?.codec.width ?? 0,
        height: video?.codec.height ?? 0,
        fps: video?.codec.frameRate ?? 0,
        bitRate: info.bitRate,
        videoCodec: video?.codec.codec ?? '',
        audioCodec: audio?.codec.codec ?? '',
        audioChannels: audio?.codec.channels ?? 0,
        format: info.format ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openWithMpv() async {
    if (_openingMpv) return;
    _openingMpv = true;
    try {
      final cached = _currentPlay;
      final useCached =
          cached != null && _currentPlayIndex == _index && cached.playable;
      final play = useCached ? cached : await _resolve(_index);
      if (play == null || !play.playable) {
        _toast(
          play?.message.isNotEmpty == true ? play!.message : '当前地址无法交给 MPV 播放',
        );
        return;
      }
      if (!await _warmUpExternalPlay(play)) return;
      await _saveProgress();
      final source = _app.preparePlay(play, forceRelay: true);
      AppLog.i(
        'player',
        '交给 Yaozhi MPV 前${useCached ? '复用当前播放地址' : '重新取链'} '
            'index=$_index 原地址=${redactUrl(play.url)} '
            'MPV地址=${redactUrl(source.url)} len=${source.url.length}',
      );
      final playlist = await _externalPlaylistPath(currentUrl: source.url);
      await MpvExtension.instance.open(
        playlist ?? source.url,
        headers: playlist == null ? source.headers : const {},
        startSeconds: playlist == null ? _position.inSeconds : 0,
      );
      // MPV 已在读本机 /chunk：页面 dispose 时保留取流 JVM，否则外部播放器 404。
      _handedToExternalPlayer = true;
      _app.sourceService.jar.holdPlaybackForExternal();
      if (!mounted) return;
      _toast(
        playlist == null
            ? '已在 Yaozhi MPV 中打开'
            : '已在 Yaozhi MPV 中打开（共 ${_episodes.length} 集选集）',
      );
      // 已经交给外部播放器：退掉内置播放器页，控制器、置顶/小窗状态都随
      // dispose 释放；取流 JVM 由上面的 holdPlaybackForExternal 保活。
      unawaited(_exitPage());
    } catch (e, s) {
      AppLog.e('player', 'Yaozhi MPV 启动失败', e, s);
      _toast('$e');
    } finally {
      _openingMpv = false;
    }
  }

  /// 识别直播流：fvp 的 isLive() 优先；拿不到时用时长上限哨兵兜底。
  bool _detectLive(VideoPlayerController controller) {
    if (_mdkEnabled) {
      try {
        if (controller.isLive()) return true;
      } catch (_) {
        // 非 fvp 内核没有 isLive
      }
    }
    // libmdk 对未知时长的直播会返回接近 Duration 上限的时长。
    return controller.value.duration > const Duration(hours: 24);
  }

  Widget _videoView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    final value = controller.value;
    final video = VideoPlayer(controller);
    final aspect = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
    final width = value.size.width <= 0 ? 1280.0 : value.size.width;
    final height = value.size.height <= 0 ? 720.0 : value.size.height;
    return switch (_fit) {
      PlayerFit.contain => Center(
        child: AspectRatio(aspectRatio: aspect, child: video),
      ),
      PlayerFit.fill => SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(width: width, height: height, child: video),
        ),
      ),
      PlayerFit.cover => ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(width: width, height: height, child: video),
          ),
        ),
      ),
      PlayerFit.ratio169 => Center(
        child: AspectRatio(aspectRatio: 16 / 9, child: video),
      ),
      PlayerFit.ratio43 => Center(
        child: AspectRatio(aspectRatio: 4 / 3, child: video),
      ),
      PlayerFit.original => ClipRect(
        child: Center(
          child: SizedBox(width: width, height: height, child: video),
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _fsAnim,
        builder: (context, child) {
          // 只做合成层的缩放 + 黑色压暗，不对整页做 Opacity/saveLayer，
          // 4K 视频全屏时也不会掉帧。
          final t = Curves.easeOutCubic.transform(_fsAnim.value);
          final scale = _fullscreen ? 1.045 - 0.045 * t : 0.955 + 0.045 * t;
          // 窗口切换瞬间整屏压黑，视觉上只剩「从黑场淡入并归位」，
          // 完全看不到系统窗口从小变大的硬跳。
          final dim = 1 - t;
          return Stack(
            fit: StackFit.expand,
            children: [
              Transform.scale(
                scale: scale,
                alignment: Alignment.center,
                child: child,
              ),
              if (dim > 0)
                IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
                ),
            ],
          );
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              _onWheelVolume(event.scrollDelta.dy);
            },
            child: MouseRegion(
              cursor: _cursorVisible
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              // 鼠标移动只维持光标可见，不唤出控制栏（单击才唤出）。
              onHover: (_) => _onPointerMove(),
              child: GestureDetector(
                // 单击切换控制栏；双击全屏。二者由 Flutter 手势仲裁区分：
                // 双击判定窗口内的第二次点击会取消 onTap，因此快速双击不会
                // 顺带把控制栏切一下。
                // opaque：加载中/无控制栏时子级（进度圈、弹幕层）不吸收点击，
                // 默认的 deferToChild 会导致单击落空、无法唤出控制栏返回。
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: () => unawaited(_toggleFullscreen()),
                // 手机：画面任意位置左右滑动 = 拖动进度（松手后 seek）。
                onHorizontalDragStart: _isMobile ? _onSeekDragStart : null,
                onHorizontalDragUpdate: _isMobile ? _onSeekDragUpdate : null,
                onHorizontalDragEnd: _isMobile ? _onSeekDragEnd : null,
                onHorizontalDragCancel: _isMobile ? _onSeekDragCancel : null,
                  onVerticalDragStart: _isAndroid ? _onVerticalDragStart : null,
                  onVerticalDragUpdate: _isAndroid ? _onVerticalDragUpdate : null,
                  onVerticalDragEnd: _isAndroid ? _onVerticalDragEnd : null,
                  onVerticalDragCancel: _isAndroid ? _onVerticalDragCancel : null,
                onLongPressStart: (_) => _startHoldRate(),
                onLongPressEnd: (_) => _endHoldRate(),
                onLongPressCancel: _endHoldRate,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _videoView(),
                    DanmakuOverlay(
                      items: _danmaku,
                      position:
                          _position +
                          Duration(
                            milliseconds: (_app.danmakuSettings.offset * 1000)
                                .round(),
                          ),
                      enabled: _danmakuEnabled && !_live && !_mini,
                      playing: _playing && !_buffering && !_resolving,
                      rate: _rate,
                      fontSize: _app.danmakuSettings.fontSize,
                      opacity: _app.danmakuSettings.opacity,
                      speed: _app.danmakuSettings.speed,
                      density: _app.danmakuSettings.density,
                      regionRatio: _app.danmakuSettings.regionRatio,
                    ),
                    if (_bufferingHint || _resolving)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    if (_error.isNotEmpty && !_buffering)
                      Center(
                        child: Container(
                          margin: const EdgeInsets.all(28),
                          padding: const EdgeInsets.all(22),
                          constraints: const BoxConstraints(maxWidth: 520),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Colors.white70,
                                size: 36,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _error,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 10,
                                alignment: WrapAlignment.center,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: () => _openEpisode(
                                      index: _index,
                                      startMs: _position.inMilliseconds,
                                    ),
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: const Text('重试'),
                                  ),
                                  if (!_ephemeral)
                                    FilledButton.tonalIcon(
                                      onPressed: _switchSource,
                                      icon: const Icon(
                                        Icons.swap_horiz_rounded,
                                      ),
                                      label: const Text('换源'),
                                    ),
                                  if (_mpvReady)
                                    FilledButton.tonalIcon(
                                      onPressed: _openWithMpv,
                                      icon: const Icon(
                                        Icons.open_in_new_rounded,
                                      ),
                                      label: const Text('用 MPV 播放'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    AnimatedOpacity(
                      opacity: _controls ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: Stack(
                          children: [
                            _topBar(context),
                            if (!_mini)
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!_live)
                                      _roundButton(
                                        icon: Icons.skip_previous_rounded,
                                        onTap: _index > 0 ? () => _switchTo(_index - 1) : null,
                                      ),
                                    if (!_live) const SizedBox(width: 22),
                                    _roundButton(
                                      icon: _playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 64,
                                      onTap: _togglePlay,
                                    ),
                                    if (!_live) const SizedBox(width: 22),
                                    if (!_live)
                                      _roundButton(
                                        icon: Icons.skip_next_rounded,
                                        onTap: _index + 1 < _episodes.length ? () => _switchTo(_index + 1) : null,
                                      ),
                                  ],
                                ),
                              ),
                            _bottomBar(context),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 110,
                      child: Center(
                        child: VolumeHud(
                          volume: _volume,
                          visible: _volumeHudVisible,
                        ),
                      ),
                    ),
                    _seekDragHud(),
          _androidGestureHud(),
                    if (_detailsVisible && !_mini) _detailsOverlay(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final mini = _mini;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          8,
          MediaQuery.paddingOf(context).top + 8,
          12,
          24,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        // 播放器页没有自绘标题栏，顶栏这一行同时作为窗口拖拽区。
        child: windowDragArea(
          Row(
            children: [
              if (!mini)
                IconButton(
                  onPressed: _requestExit,
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HoverMarqueeText(
                      _detail.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    HoverMarqueeText(
                      '${_live ? '直播' : (_episodeName.isEmpty ? '正片' : _episodeName)} · ${_site.displayName} · $_flag',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isDesktop)
                IconButton(
                  tooltip: _alwaysOnTop ? '取消窗口置顶' : '窗口置顶（仅本次播放）',
                  onPressed: _toggleAlwaysOnTop,
                  icon: _alwaysOnTop
                      ? const Icon(Icons.push_pin_rounded, color: Colors.white)
                      : const Icon(
                          Icons.push_pin_outlined,
                          color: Colors.white,
                        ),
                ),
              if (!mini && _isDesktop)
                IconButton(
                  tooltip: '投屏到电视（DLNA）',
                  onPressed: _castToDevice,
                  icon: const Icon(Icons.cast_rounded, color: Colors.white),
                ),
              if (!mini && _isDesktop)
                IconButton(
                  tooltip: _app.watchParty.active ? '一起看（进行中）' : '一起看（局域网同看）',
                  onPressed: _showWatchParty,
                  icon: Icon(
                    _app.watchParty.active
                        ? Icons.groups_rounded
                        : Icons.groups_outlined,
                    color: _app.watchParty.active
                        ? const Color(0xFF7DD3FC)
                        : Colors.white,
                  ),
                ),
              if (_isDesktop)
                IconButton(
                  tooltip: _mini ? '回归正常窗口' : '小窗播放（始终置顶）',
                  onPressed: _toggleMini,
                  icon: _mini
                      ? const Icon(
                          Icons.open_in_full_rounded,
                          color: Colors.white,
                        )
                      : const Icon(
                          Icons.picture_in_picture_alt_outlined,
                          color: Colors.white,
                        ),
                ),
              if (!mini)
                IconButton(
                  tooltip: _sleepTimer.active
                      ? '睡眠定时：${sleepTimerBadge(_sleepTimer.state, DateTime.now().millisecondsSinceEpoch)}'
                      : '睡眠定时',
                  onPressed: _openSleepTimer,
                  icon: Icon(
                    _sleepTimer.active
                        ? Icons.bedtime_rounded
                        : Icons.bedtime_outlined,
                    color: _sleepTimer.active
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white,
                  ),
                ),
              if (!mini)
                IconButton(
                  tooltip: '播放列表',
                  onPressed: _showEpisodes,
                  icon: const Icon(
                    Icons.format_list_bulleted_rounded,
                    color: Colors.white,
                  ),
                ),
              if (!mini && hasCustomWindowChrome)
                IconButton(
                  tooltip: '退出软件',
                  onPressed: closeAppWindow,
                  icon: const Icon(
                    Icons.power_settings_new_rounded,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          enabled: !_fullscreen,
        ),
      ),
    );
  }

  /// 直播时替代进度条的一行：红点 + 直播 + 实时。
  Widget _liveHeadline() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '直播',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            '实时',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  /// 小窗底栏只保留暂停和下一集，避免 480×292 里塞满按钮。
  Widget _miniBottomBar(BuildContext context) {
    final canNext = !_live && _index + 1 < _episodes.length;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          14,
          24,
          14,
          MediaQuery.paddingOf(context).bottom + 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _togglePlay,
              iconSize: 34,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 36),
            IconButton(
              tooltip: '下一集',
              onPressed: canNext ? () => _switchTo(_index + 1) : null,
              iconSize: 34,
              icon: Icon(
                Icons.skip_next_rounded,
                color: canNext ? Colors.white : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    if (_mini) return _miniBottomBar(context);
    final total = _duration.inMilliseconds <= 0 ? 1 : _duration.inMilliseconds;
    final value = _position.inMilliseconds.clamp(0, total).toDouble();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          14,
          30,
          14,
          MediaQuery.paddingOf(context).bottom + 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_live)
              _liveHeadline()
            else
              Row(
                children: [
                  Text(
                    _fmt(_position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Expanded(
                    // 进度条右键一次点选即生效：开头 5 分钟内取片头、结尾 5 分钟内取片尾；
                    // 右键双击则清除本资源的记录。
                    child: LayoutBuilder(
                      builder: (_, constraints) => Listener(
                        onPointerDown: (event) {
                          if (event.kind != PointerDeviceKind.mouse) return;
                          if ((event.buttons & kSecondaryMouseButton) != 0) {
                            _onProgressSecondaryDown(
                              width: constraints.maxWidth,
                              dx: event.localPosition.dx,
                            );
                            return;
                          }
                          // 左键按下（拖动 / 跳转）就放弃还没执行的右键取点。
                          _cancelPendingSkipPick();
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 已缓冲区间：画在轨道下方，位置与 Slider 可见轨道对齐
                            // （两端各内缩 overlay 半径 12）。
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _BufferedBarPainter(
                                    played: total <= 0
                                        ? 0
                                        : (value / total).clamp(0.0, 1.0),
                                    buffered: total <= 0
                                        ? 0
                                        : (_bufferedEndMs() / total).clamp(
                                            0.0,
                                            1.0,
                                          ),
                                    inset: 12,
                                  ),
                                ),
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: value,
                                max: total.toDouble(),
                                onChanged: (v) => setState(
                                  () => _position = Duration(
                                    milliseconds: v.round(),
                                  ),
                                ),
                                onChangeEnd: (v) =>
                                    _seekTo(Duration(milliseconds: v.round())),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Text(
                    _fmt(_duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            Row(crossAxisAlignment: CrossAxisAlignment.center,
                
              children: [
                IconButton(
                  tooltip: '刷新（重新取流）',
                  onPressed: (_refreshing || _resolving)
                      ? null
                      : _refreshPlayback,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          color: (_resolving || _index < 0)
                              ? Colors.white24
                              : Colors.white,
                        ),
                ),
                IconButton(
                  tooltip: '音量 ${(_volume * 100).round()}%（↑/↓ 调节）',
                  onPressed: _showVolume,
                  icon: Icon(_volumeIcon, color: Colors.white),
                ),
             Expanded(child: Align(alignment: Alignment.centerRight, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [if (!_live) Tooltip(message: '弹幕：点击开关，长按调节速度 / 屏占 / 屏蔽词', child: _barAction(icon: Icons.chat_bubble_outline_rounded, label: '弹幕', active: _danmakuEnabled, onTap: _toggleDanmaku, onLongPress: _showDanmakuPanel)), if (_mdkEnabled && !_live) _barAction(icon: Icons.subtitles_outlined, label: '字幕', active: _subtitleStatus.isNotEmpty, onTap: _showSubtitlePanel), if (_mdkEnabled && !_live && _audioOptions.length > 1) _barAction(icon: Icons.graphic_eq_rounded, label: '音轨', onTap: _showAudioTracks), if (!_live) Tooltip(message: _skipIntro > 0 ? '点按以当前进度覆盖片头，长按清除${_skipInheritedFrom.isEmpty ? '' : '（来自$_skipInheritedFrom）'}' : '点按以当前进度设为片头', child: _barAction(icon: Icons.first_page_rounded, label: _skipIntro > 0 ? '片头 ${_fmt(Duration(seconds: _skipIntro))}' : '片头', active: _skipIntro > 0, onTap: _markSkipIntroFromCurrent, onLongPress: _clearSkipIntro)), if (!_live) Tooltip(message: _skipOutro > 0 ? '点按以当前剩余时长覆盖片尾，长按清除${_skipInheritedFrom.isEmpty ? '' : '（来自$_skipInheritedFrom）'}' : '点按以当前剩余时长设为片尾', child: _barAction(icon: Icons.last_page_rounded, label: _skipOutro > 0 ? '片尾 ${_fmt(Duration(seconds: _skipOutro))}' : '片尾', active: _skipOutro > 0, onTap: _markSkipOutroFromCurrent, onLongPress: _clearSkipOutro)), _barAction(icon: Icons.analytics_outlined, label: '详情', active: _detailsVisible, onTap: _toggleDetails, onLongPress: _showDetailsSettings), IconButton(tooltip: '播放设置（画面比例 / 音轨 / 外部播放器）', onPressed: _showPlaybackSettings, icon: const Icon(Icons.tune_rounded, color: Colors.white)), if (_mpvReady) TextButton.icon(onPressed: _openWithMpv, icon: const Icon(Icons.open_in_new_rounded, color: Colors.white70, size: 18), label: const Text('MPV', style: TextStyle(color: Colors.white70, fontSize: 12))), TextButton.icon(onPressed: _showSpeed, icon: const Icon(Icons.speed_rounded, color: Colors.white70, size: 18), label: Text('${_rate.toStringAsFixed(_rate % 1 == 0 ? 0 : 2)}x', style: const TextStyle(color: Colors.white70, fontSize: 12))),],),),),),
              if (_isAndroid)
                IconButton(
                  tooltip: _portraitFullscreen ? '横屏全屏' : '竖屏全屏',
                  onPressed: () {
                    unawaited(
                      _applyAndroidOrientation(
                        portrait: !_portraitFullscreen,
                        manual: true,
                      ),
                    );
                  },
                  icon: Icon(
                    _portraitFullscreen
                        ? Icons.stay_current_landscape_rounded
                        : Icons.stay_current_portrait_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
                      IconButton(
                        tooltip: '全屏（F / Enter）',
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                          _fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    VoidCallback? onTap,
    double size = 52,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: onTap == null ? Colors.white24 : Colors.white, size: size * 0.5),
        ),
      ),
    );
  }

  /// 底栏的文字按钮（支持长按，「详情」靠长按打开自定义面板）。
  Widget _barAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool active = false,
  }) {
    final color = active ? Colors.white : Colors.white70;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<void> _showEpisodes() async {
    var sheetFlag = _flag;
    final lineScroll = ScrollController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final theme = Theme.of(ctx);
            final flags = <String>[..._detail.flags];
            if (flags.isEmpty) flags.add(_flag);
            if (flags.length == 1 && flags.first != sheetFlag) {
              flags.insert(0, sheetFlag);
            }
            final episodes = _detail.episodeList(sheetFlag);
            // 当前线路高亮正在播放的集；切到别的线路后按集名 / 集号找到同一集。
            final activeIndex = sheetFlag == _flag
                ? _index
                : matchEpisodeIndex(episodes, _episodeName, _index);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('选集', style: theme.textTheme.titleLarge),
                    if (flags.length > 1) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('线路', style: theme.textTheme.bodySmall),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ScrollConfiguration(
                              behavior: const MouseDragScrollBehavior(),
                              child: Scrollbar(
                                controller: lineScroll,
                                thumbVisibility: true,
                                interactive: true,
                                scrollbarOrientation:
                                    ScrollbarOrientation.bottom,
                                child: SingleChildScrollView(
                                  controller: lineScroll,
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      for (final flag in flags)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: _lineChip(
                                            ctx,
                                            label: flag.isEmpty ? '默认线路' : flag,
                                            selected: flag == sheetFlag,
                                            onTap: () {
                                              if (flag == sheetFlag) return;
                                              setSheet(() => sheetFlag = flag);
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      '${sheetFlag.isEmpty ? '默认线路' : sheetFlag} · '
                      '共 ${episodes.length} 集',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 120,
                              mainAxisExtent: 44,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: episodes.length,
                        itemBuilder: (_, index) {
                          final active = index == activeIndex;
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              if (sheetFlag == _flag) {
                                if (index != _index) _switchTo(index);
                              } else {
                                _switchLine(sheetFlag, index);
                              }
                            },
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: active
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.2,
                                      )
                                    : theme.colorScheme.surfaceContainerHighest
                                          .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: active
                                      ? theme.colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                              child: HoverMarqueeText(
                                episodes[index].name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: active
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    lineScroll.dispose();
  }

  /// 选集面板上方的线路按钮。
  Widget _lineChip(
    BuildContext ctx, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(ctx);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.18)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

}

class _AudioOption {
  const _AudioOption({
    required this.index,
    required this.codec,
    required this.channels,
    required this.language,
    required this.title,
  });

  /// 封装内的流索引（传给 fvp `setAudioTracks`）。
  final int index;
  final String codec;
  final int channels;
  final String language;
  final String title;
}

/// 桌面端从 fvp（libmdk）读到的媒体信息，供「详情」悬浮层显示。
class _MediaStats {
  const _MediaStats({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitRate = 0,
    this.videoCodec = '',
    this.audioCodec = '',
    this.audioChannels = 0,
    this.format = '',
  });

  final int width;
  final int height;
  final double fps;

  /// 实时码率（bit/s），播放中由 libmdk 更新，用作「实时网速」。
  final int bitRate;
  final String videoCodec;
  final String audioCodec;
  final int audioChannels;
  final String format;
}

/// 进度条上的「已缓冲」条：从播放位置画到缓冲区末尾。
///
/// 与 Slider 的可见轨道对齐：轨道两端各内缩 overlay 半径（这里 12），
/// 否则缓冲条会比轨道宽出一截，看起来像错位。
class _BufferedBarPainter extends CustomPainter {
  const _BufferedBarPainter({
    required this.played,
    required this.buffered,
    required this.inset,
  });

  /// 已播放比例（0–1）。
  final double played;

  /// 已缓冲比例（0–1）。
  final double buffered;

  /// 轨道两端的缩进（= SliderTheme.overlayShape 的半径）。
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final track = size.width - inset * 2;
    if (track <= 0 || buffered <= played) return;
    final left = inset + track * played;
    final right = inset + track * buffered;
    final centerY = size.height / 2;
    final rect = Rect.fromLTRB(left, centerY - 1.5, right, centerY + 1.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()..color = Colors.white.withValues(alpha: 0.45),
    );
  }

  @override
  bool shouldRepaint(covariant _BufferedBarPainter oldDelegate) =>
      oldDelegate.played != played ||
      oldDelegate.buffered != buffered ||
      oldDelegate.inset != inset;
}





