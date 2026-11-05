part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages> {
  String? error;

  bool inProgress = false;

  late _ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  /// Handle jumping to last page when _jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader._jumpToLastPageOnLoad) {
      reader._page = reader.maxPage;
      reader._jumpToLastPageOnLoad = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    var loadingChapter = reader.chapter;
    var res = await reader.loadChapterImages(loadingChapter);
    if (!mounted || reader.chapter != loadingChapter) {
      inProgress = false;
      return;
    }
    if (res.error) {
      setState(() {
        error = res.errorMessage;
        reader.isLoading = false;
        inProgress = false;
      });
    } else {
      setState(() {
        reader.images = res.data;
        reader.isLoading = false;
        inProgress = false;
        _handleJumpToLastPage();
        Future.microtask(() {
          reader.updateHistory();
        });
      });
    }
    context.readerScaffold.update();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    implements _ImageViewController {
  late PageController controller;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  var photoViewControllers = <int, PhotoViewController>{};

  late _ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return !reader.showSingleImageOnFirstPage()
        ? (reader.images!.length / reader.imagesPerPage).ceil()
        : 1 + ((reader.images!.length - 1) / reader.imagesPerPage).ceil();
  }

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    super.initState();
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      _cachePage(i, i == startPage + 1 || i == startPage - 1);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      shouldPreCache
          ? _precacheImage(i + 1, context)
          : _preDownloadImage(i + 1, context);
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return _EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        fingers++;
      },
      onPointerUp: (event) {
        fingers--;
      },
      onPointerCancel: (event) {
        fingers--;
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          var controller = photoViewControllers[reader.page]!;
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            cache(index);

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewControllers[index],
                imageProvider: _createImageProviderFromKey(
                  pageImages[0],
                  context,
                  startIndex + 1,
                ),
                fit: BoxFit.contain,
                errorBuilder: (_, error, s, retry) {
                  return NetworkError(message: error.toString(), retry: retry);
                },
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewControllers[index],
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages, startIndex),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: context.colorScheme.surface,
            ),
            child: Center(
              child: SizedBox(
                width: 20.0,
                height: 20.0,
                child: CircularProgressIndicator(
                  backgroundColor: context.colorScheme.surfaceContainerHigh,
                  value: event == null || event.expectedTotalBytes == null
                      ? null
                      : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
                ),
              ),
            ),
          );
        },
        onPageChanged: (i) {
          if (i == 0) {
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalPages);
            }
          } else {
            reader.setPage(i);
            context.readerScaffold.update();
            // Auto close toolbar when entering chapter comments page
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          // Remove other pages' controllers to reset their state.
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != i) {
              photoViewControllers.remove(key);
            }
          }
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
    if (reverse) {
      images = images.reversed.toList();
    }

    List<Widget> imageWidgets;

    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[0],
              context,
              startIndex + 1,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[1],
              context,
              startIndex + 2,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        ImageProvider imageProvider = _createImageProviderFromKey(
          imageKey,
          context,
          startIndex,
        );
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  Future<void> animateToPage(int page) {
    if ((page - controller.page!.round()).abs() > 1) {
      controller.jumpToPage(page > controller.page! ? page - 1 : page + 1);
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    controller.jumpToPage(page);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page]!;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toPage(reader.page + 1);
      } else if (forward == false) {
        reader.toPage(reader.page - 1);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toPage(reader.page + 1);
          } else if (forward == false) {
            reader.toPage(reader.page - 1);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return (await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      ))!.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

class _ContinuousSegment {
  _ContinuousSegment(this.chapter, this.images);

  final int chapter;
  final List<String> images;

  int get length => images.length;
}

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key});

  @override
  State<_ContinuousMode> createState() => _ContinuousModeState();
}

class _ContinuousModeState extends State<_ContinuousMode>
    implements _ImageViewController {
  late _ReaderState reader;

  /// Unique id for this controller instance. It is part of the PageStorage
  /// key so a new controller (for example after switching the reading
  /// direction) never restores the old list's absolute item index.
  static int _instanceCounter = 0;

  late final int _instanceId = _instanceCounter++;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  /// A sliding window of chapters. Consecutive chapters are stitched into one
  /// list so scrolling never has to stop at a chapter boundary.
  final List<_ContinuousSegment> _segments = [];

  /// Keys of images that were already requested for pre-download.
  final Set<String> _prefetched = {};

  int _currentSegment = 0;

  /// Used by [ScrollablePositionedList] when the list is rebuilt after an
  /// explicit chapter jump.
  int _initialScrollIndex = 0;

  /// Last first-visible index for which images were prefetched. Position
  /// updates fire on every scroll frame, but the set of images to prefetch
  /// only changes when the first visible item changes.
  int? _lastPrefetchIndex;

  int _listKey = 0;

  /// Generation counter used to discard asynchronous results after the window
  /// was explicitly reset.
  int _generation = 0;

  bool _loadingNext = false;
  bool _loadingPrev = false;
  bool _loadingChapter = false;
  bool _adjusting = false;

  String? _chapterError;

  DateTime? _nextRetryAt;
  DateTime? _prevRetryAt;

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  bool isZoomedIn = false;
  bool isLongPressing = false;

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  int get preCacheCount => appdata.settings["preloadImageCount"];

  /// Start loading the next chapter when this many images are left. A little
  /// extra lead time keeps the transition invisible on slow networks.
  int get _preLoadThreshold => math.max(preCacheCount * 2, 6);

  /// Whether the next chapter should be stitched into the list automatically.
  bool get _autoLoadNextChapter =>
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'continuousAutoLoadNextChapter',
      ) !=
      false;

  int get _imageCount {
    var count = 0;
    for (var segment in _segments) {
      count += segment.length;
    }
    return count;
  }

  /// The list also contains one trailing placeholder while the next chapter is
  /// loading.
  int get _itemCount => _imageCount + (_loadingNext ? 1 : 0);

  _ContinuousSegment? get _currentSegmentData {
    if (_segments.isEmpty) return null;
    var index = _currentSegment.clamp(0, _segments.length - 1).toInt();
    return _segments[index];
  }

  int _indexOfImage(int segmentIndex, int page) {
    var index = page - 1;
    for (var i = 0; i < segmentIndex; i++) {
      index += _segments[i].length;
    }
    return index;
  }

  ({int segment, int page})? _locateImage(int index) {
    if (index < 0) return null;
    var offset = 0;
    for (var i = 0; i < _segments.length; i++) {
      var segment = _segments[i];
      if (index < offset + segment.length) {
        return (segment: i, page: index - offset + 1);
      }
      offset += segment.length;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    reader = context.reader;
    reader._imageViewController = this;
    var images = reader.images;
    if (images != null && images.isNotEmpty) {
      _segments.add(_ContinuousSegment(reader.chapter, images));
      var page = reader.page.clamp(1, images.length).toInt();
      if (page != reader.page) {
        reader._page = page;
        reader.updateHistory();
      }
      _initialScrollIndex = page - 1;
    }
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      context.readerScaffold.setFloatingButton(0);
      _prefetch(_initialScrollIndex);
      _ensureNeighbors();
    });
  }

  @override
  void dispose() {
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    if (identical(reader._imageViewController, this)) {
      reader._imageViewController = null;
    }
    super.dispose();
  }

  void onPositionChanged() {
    if (_adjusting) return;
    var positions =
        itemPositionsListener.itemPositions.value
            .where(
              (position) => position.index >= 0 && position.index < _imageCount,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (positions.isEmpty) {
      _ensureNeighbors();
      return;
    }
    var first = positions.first;
    var last = positions.last;
    var location = _locateImage(first.index);
    if (location == null) return;
    _initialScrollIndex = first.index;
    if (_lastPrefetchIndex != first.index) {
      _lastPrefetchIndex = first.index;
      _prefetch(first.index);
    }
    _enterSegment(location.segment, location.page);
    if (last.index >= _imageCount - _preLoadThreshold) {
      _ensureNextChapter();
    }
    if (first.index == 0) {
      _ensurePrevChapter();
    }
  }

  /// Move to the next image in the merged chapter window. Used by tap-to-turn
  /// and volume keys so they can cross a chapter boundary without a reload.
  bool toNextImage() {
    if (_segments.isEmpty) return false;
    var current = _indexOfImage(_currentSegment, reader.page);
    var next = current + 1;
    if (next >= _imageCount) return false;
    return _jumpToImageIndex(
      next,
      animate: reader.enablePageAnimation(reader.cid, reader.type),
    );
  }

  bool toPrevImage() {
    if (_segments.isEmpty) return false;
    var current = _indexOfImage(_currentSegment, reader.page);
    var prev = current - 1;
    if (prev < 0) return false;
    return _jumpToImageIndex(
      prev,
      animate: reader.enablePageAnimation(reader.cid, reader.type),
    );
  }

  bool _jumpToImageIndex(int index, {bool animate = false}) {
    var location = _locateImage(index);
    if (location == null || !itemScrollController.isAttached) return false;
    _enterSegment(location.segment, location.page, trim: false);
    _initialScrollIndex = index;
    if (animate) {
      itemScrollController.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else {
      itemScrollController.jumpTo(index: index);
    }
    return true;
  }

  /// Update the reader state to the chapter currently at the top/left of the
  /// viewport. History, the app bar and the chapter list all read from here.
  void _enterSegment(int segmentIndex, int page, {bool trim = true}) {
    if (segmentIndex < 0 || segmentIndex >= _segments.length) return;
    var segment = _segments[segmentIndex];
    if (_currentSegment == segmentIndex &&
        reader.chapter == segment.chapter &&
        reader.page == page) {
      if (trim) _trimSegments();
      return;
    }
    _currentSegment = segmentIndex;
    reader.chapter = segment.chapter;
    reader.images = segment.images;
    if (reader.page != page) {
      reader.page = page;
    } else {
      reader.updateHistory();
    }
    context.readerScaffold.update();
    if (trim) _trimSegments();
  }

  void _prefetch(int globalIndex) {
    // Prefetch in both directions: while reading forward this warms up the
    // upcoming images, while scrolling back it also warms up the images just
    // above the viewport.
    var start = math.max(0, globalIndex - 2);
    var end = globalIndex + preCacheCount;
    for (var i = start; i <= end; i++) {
      var location = _locateImage(i);
      if (location == null) continue;
      var segment = _segments[location.segment];
      var key = '${segment.chapter}:${location.page}';
      if (!_prefetched.add(key)) continue;
      _preDownloadImageForChapter(
        segment.chapter,
        location.page,
        segment.images[location.page - 1],
      );
    }
  }

  void _preDownloadImageForChapter(int chapter, int page, String imageKey) {
    if (imageKey.startsWith("file://")) return;
    ImageDownloader.loadComicImage(
      imageKey,
      reader.type.comicSource?.key,
      reader.cid,
      reader.eidOf(chapter),
    );
  }

  void _ensureNeighbors() {
    if (_segments.isEmpty) return;
    var segment = _currentSegmentData;
    if (segment == null) return;
    if (reader.page >= segment.length - _preLoadThreshold) {
      _ensureNextChapter();
    }
    if (_currentSegment == 0 && reader.page == 1) {
      _ensurePrevChapter();
    }
  }

  Future<void> _ensureNextChapter() async {
    if (!_autoLoadNextChapter) return;
    if (_loadingNext || _segments.isEmpty) return;
    // The next chapter is already in the window; nothing to do.
    if (_currentSegment != _segments.length - 1) return;
    if (_nextRetryAt != null && DateTime.now().isBefore(_nextRetryAt!)) {
      return;
    }
    var last = _segments.last;
    var nextChapter = last.chapter + 1;
    if (nextChapter > reader.maxChapter) return;
    // Keep the existing group boundary behaviour: do not silently cross into
    // another chapter group.
    if (reader.isLastChapterOfGroupOf(last.chapter)) return;
    if (_segments.any((segment) => segment.chapter == nextChapter)) return;

    var generation = _generation;
    setState(() {
      _loadingNext = true;
    });
    var res = await reader.loadChapterImages(nextChapter);
    if (!mounted || generation != _generation) return;
    if (!_autoLoadNextChapter) {
      setState(() {
        _loadingNext = false;
      });
      return;
    }
    if (res.error || res.data.isEmpty) {
      _nextRetryAt = DateTime.now().add(const Duration(seconds: 5));
      Log.error(
        "Reader",
        "Failed to load next chapter $nextChapter: ${res.errorMessage}",
      );
      if (mounted) {
        setState(() {
          _loadingNext = false;
        });
      }
      return;
    }
    _nextRetryAt = null;
    if (_segments.isEmpty ||
        _currentSegment != _segments.length - 1 ||
        _segments.any((segment) => segment.chapter == nextChapter) ||
        _segments.last.chapter + 1 != nextChapter) {
      if (mounted) {
        setState(() {
          _loadingNext = false;
        });
      }
      return;
    }
    setState(() {
      _segments.add(_ContinuousSegment(nextChapter, res.data));
      _loadingNext = false;
    });
    _prefetch(_indexOfImage(_segments.length - 1, 1));
  }

  Future<void> _ensurePrevChapter() async {
    if (_loadingPrev || _segments.isEmpty) return;
    // The previous chapter is already in the window; nothing to do.
    if (_currentSegment != 0) return;
    if (_prevRetryAt != null && DateTime.now().isBefore(_prevRetryAt!)) {
      return;
    }
    var first = _segments.first;
    var prevChapter = first.chapter - 1;
    if (prevChapter < 1) return;
    if (reader.isFirstChapterOfGroupOf(first.chapter)) return;
    if (_segments.any((segment) => segment.chapter == prevChapter)) return;

    var generation = _generation;
    setState(() {
      _loadingPrev = true;
    });
    var res = await reader.loadChapterImages(prevChapter);
    if (!mounted || generation != _generation) return;
    if (res.error || res.data.isEmpty) {
      _prevRetryAt = DateTime.now().add(const Duration(seconds: 5));
      Log.error(
        "Reader",
        "Failed to load previous chapter $prevChapter: ${res.errorMessage}",
      );
      if (mounted) {
        setState(() {
          _loadingPrev = false;
        });
      }
      return;
    }
    _prevRetryAt = null;
    if (_segments.isEmpty ||
        _currentSegment != 0 ||
        _segments.any((segment) => segment.chapter == prevChapter) ||
        _segments.first.chapter - 1 != prevChapter) {
      if (mounted) {
        setState(() {
          _loadingPrev = false;
        });
      }
      return;
    }
    var segment = _ContinuousSegment(prevChapter, res.data);
    var position = _captureVisiblePosition();
    if (position == null) {
      // The list is not attached yet; keep the loaded images in the cache and
      // retry when the user actually scrolls near the top.
      if (mounted) {
        setState(() {
          _loadingPrev = false;
        });
      }
      return;
    }
    setState(() {
      _segments.insert(0, segment);
      _currentSegment++;
      _loadingPrev = false;
      _initialScrollIndex += segment.length;
      _lastPrefetchIndex = null;
    });
    _restorePosition(position.index + segment.length, position.alignment);
  }

  /// Drop chapters that are far ahead of the current one. Chapters behind the
  /// current position are intentionally kept: removing them would shift the
  /// absolute item indices and could cause a visible jump while scrolling.
  void _trimSegments() {
    const keepAfter = 3;
    var removeAfter = _segments.length - _currentSegment - 1 - keepAfter;
    if (removeAfter <= 0) return;
    setState(() {
      _segments.removeRange(_segments.length - removeAfter, _segments.length);
    });
  }

  ({int index, double alignment})? _captureVisiblePosition() {
    var controller = _scrollController;
    if (controller == null || !controller.hasClients) return null;
    var positions = itemPositionsListener.itemPositions.value
        .where(
          (position) => position.index >= 0 && position.index < _imageCount,
        )
        .toList();
    if (positions.isEmpty) return null;
    positions.sort((a, b) => a.index.compareTo(b.index));
    var first = positions.first;
    var viewport = controller.position.viewportDimension;
    if (viewport <= 0) return null;
    var alignment = first.itemLeadingEdge / viewport;
    if (!alignment.isFinite) return null;
    return (index: first.index, alignment: alignment);
  }

  void _restorePosition(int index, double alignment) {
    if (index < 0) index = 0;
    if (index >= _imageCount) index = _imageCount - 1;
    if (index < 0) return;
    _adjusting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: index, alignment: alignment);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _adjusting = false;
      });
    });
  }

  /// Called when the user explicitly selects a chapter (chapter list, next /
  /// previous buttons, volume keys, ...). If the target chapter is already in
  /// the window we only scroll to it; otherwise the window is rebuilt.
  Future<void> jumpToChapter(int chapter, {bool toLastPage = false}) async {
    // A previous explicit jump is still loading; restart with the latest
    // target instead of operating on a detached list.
    if (_loadingChapter) {
      await _loadChapterAndReplace(chapter, toLastPage: toLastPage);
      return;
    }
    var existing = _segments.indexWhere(
      (segment) => segment.chapter == chapter,
    );
    if (existing >= 0) {
      // Invalidate any background chapter load so a stale result cannot
      // replace the chapter the user just selected.
      _generation++;
      _nextRetryAt = null;
      _prevRetryAt = null;
      if (_loadingNext || _loadingPrev || _chapterError != null) {
        setState(() {
          _loadingNext = false;
          _loadingPrev = false;
          _chapterError = null;
        });
      }
      var segment = _segments[existing];
      var page = (toLastPage ? segment.length : 1)
          .clamp(1, segment.length)
          .toInt();
      _enterSegment(existing, page, trim: false);
      _initialScrollIndex = _indexOfImage(existing, page);
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: _initialScrollIndex);
      }
      return;
    }

    await _loadChapterAndReplace(chapter, toLastPage: toLastPage);
  }

  Future<void> _loadChapterAndReplace(
    int chapter, {
    bool toLastPage = false,
  }) async {
    var generation = ++_generation;
    setState(() {
      _loadingChapter = true;
      _chapterError = null;
      _loadingNext = false;
      _loadingPrev = false;
      _nextRetryAt = null;
      _prevRetryAt = null;
    });
    var res = await reader.loadChapterImages(chapter);
    if (!mounted || generation != _generation) return;
    if (res.error || res.data.isEmpty) {
      var message = res.errorMessage ?? "No images".tl;
      setState(() {
        _loadingChapter = false;
        _chapterError = message;
        // The list was detached while loading; force a fresh one so stale
        // PageStorage positions cannot override the current position.
        _listKey++;
      });
      if (_segments.isNotEmpty && mounted) {
        showToast(message: message, context: context, seconds: 1);
      }
      return;
    }
    var images = res.data;
    var page = (toLastPage ? images.length : 1).clamp(1, images.length).toInt();
    setState(() {
      _segments
        ..clear()
        ..add(_ContinuousSegment(chapter, images));
      _currentSegment = 0;
      _initialScrollIndex = page - 1;
      _lastPrefetchIndex = null;
      _listKey++;
      _loadingChapter = false;
    });
    reader.chapter = chapter;
    reader.images = images;
    reader.page = page;
    context.readerScaffold.update();
    _prefetch(page - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: page - 1);
      }
      _ensureNeighbors();
    });
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      smoothTo(event.scrollDelta.dy);
    }
  }

  bool onScaleUpdate([double? scale]) {
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingChapter) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_segments.isEmpty) {
      if (_chapterError != null) {
        return GestureDetector(
          onTap: () {
            context.readerScaffold.openOrClose();
          },
          child: SizedBox.expand(
            child: NetworkError(
              message: _chapterError!,
              retry: () {
                jumpToChapter(reader.chapter);
              },
            ),
          ),
        );
      }
      return Center(child: Text("No images".tl));
    }

    Widget widget = ScrollablePositionedList.builder(
      key: PageStorageKey<String>('continuous-$_instanceId-$_listKey'),
      initialScrollIndex: _initialScrollIndex,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        _scrollController = scrollController;
      },
      itemCount: _itemCount,
      addSemanticIndexes: false,
      scrollDirection: reader.mode == ReaderMode.continuousTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index >= _imageCount) {
          // Placeholder while the next chapter is loading.
          return Center(
            child: SizedBox(
              width: reader.mode == ReaderMode.continuousTopToBottom
                  ? double.infinity
                  : 80,
              height: reader.mode == ReaderMode.continuousTopToBottom
                  ? 80
                  : double.infinity,
              child: const Center(child: CircularProgressIndicator()),
            ),
          );
        }
        var location = _locateImage(index);
        if (location == null) {
          return const SizedBox();
        }
        var segment = _segments[location.segment];
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = _createSegmentImageProvider(
          segment,
          location.page,
          context,
        );

        // Each image is isolated in its own layer so that scrolling, the
        // page-number overlay or the top/bottom bars do not force the whole
        // viewport to be re-rasterized.
        return RepaintBoundary(
          child: ColoredBox(
            color: context.colorScheme.surface,
            child: ComicImage(
              // Medium quality resampling is expensive every frame while
              // scrolling. Switch to high quality only when the image is
              // zoomed and effectively static.
              filterQuality: isZoomedIn
                  ? FilterQuality.medium
                  : FilterQuality.low,
              image: image,
              width: width,
              height: height,
              fit: BoxFit.contain,
              onInit: (state) => imageStates.add(state),
              onDispose: (state) => imageStates.remove(state),
            ),
          ),
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        fingers++;
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode == ReaderMode.continuousTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }
        return false;
      },
      child: widget,
    );
    var width = reader.size.width;
    var height = reader.size.height;
    if (appdata.settings['limitImageWidth'] &&
        width / height > 0.7 &&
        reader.mode == ReaderMode.continuousTopToBottom) {
      width = height * 0.7;
    }

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: context.colorScheme.surface),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return const SizedBox.shrink();
  }

  @override
  Future<void> animateToPage(int page) async {
    if (_segments.isEmpty) return;
    var segment = _currentSegmentData;
    if (segment == null) return;
    var local = page.clamp(1, segment.length).toInt();
    if (!itemScrollController.isAttached) return;
    _initialScrollIndex = _indexOfImage(_currentSegment, local);
    await itemScrollController.scrollTo(
      index: _initialScrollIndex,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    if (_segments.isEmpty) return;
    var segment = _currentSegmentData;
    if (segment == null) return;
    var local = page.clamp(1, segment.length).toInt();
    _initialScrollIndex = _indexOfImage(_currentSegment, local);
    if (itemScrollController.isAttached) {
      itemScrollController.jumpTo(index: _initialScrollIndex);
    }
    _futurePosition = null;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    if (_scrollController == null || !_scrollController!.hasClients) {
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      var eid = _providerForImageKey(imageKey)?.eid ?? reader.eid;
      return (await CacheManager().findCache(
        "$imageKey@${reader.type.sourceKey}@${reader.cid}@$eid",
      ))!.readAsBytes();
    }
  }

  ReaderImageProvider? _providerForImageKey(String imageKey) {
    for (var imageState in imageStates) {
      var image = (imageState as _ComicImageState).widget.image;
      if (image is ReaderImageProvider && image.imageKey == imageKey) {
        return image;
      }
    }
    return null;
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    reader.eid,
    reader.page,
    enableResize: reader
        .mode
        .isContinuous, // For continuous mode, we need to resize the image to improve performance
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

/// Image provider for a chapter segment in the continuous reader.
ImageProvider _createSegmentImageProvider(
  _ContinuousSegment segment,
  int page,
  BuildContext context,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    segment.images[page - 1],
    reader.type.comicSource?.key,
    reader.cid,
    reader.eidOf(segment.chapter),
    page,
    // Continuous mode needs resizing to keep the memory usage reasonable.
    enableResize: true,
  );
}

/// [_precacheImage] is used to precache the image for the given page.
/// The image is cached using the flutter's [precacheImage] method.
/// The image will be downloaded and decoded into memory.
void _precacheImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  precacheImage(_createImageProvider(page, context), context);
}

/// [_preDownloadImage] is used to download the image for the given page.
/// The image is downloaded using the [CacheManager] and saved to the local storage.
void _preDownloadImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
}
