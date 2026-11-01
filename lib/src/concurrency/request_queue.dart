import "dart:async";
import "dart:collection";

extension CompleterWithTimeout<T> on Completer<T> {
  void setTimeout(Duration duration, {void Function()? onTimeout, T? returnOnTimeout}) {
    unawaited(Future.delayed(duration).then((_) {
      if (!isCompleted) {
        if (returnOnTimeout != null) {
          complete(returnOnTimeout);
        } else {
          completeError(TimeoutException("Operation timed out", duration));
        }
        onTimeout?.call();
      }
    }));
  }

  void completeIfPending(T value) {
    if (!isCompleted) {
      complete(value);
    }
  }

  void completeErrorIfPending(Object error) {
    if (!isCompleted) {
      completeError(error);
    }
  }
}

class RequestQueue {
  bool _disposed = false;

  final Completer<void> _isReady;

  /// Used to kill the message if it's taking too long to send/process
  final Duration? inFlightTimeout;

  final Queue<({FutureOr Function() data, Completer completer})> _requests = Queue();
  bool _isSending = false;
  Completer? _inFlight;

  RequestQueue({
    this.inFlightTimeout,
    Completer<void>? isReady,
  }) : _isReady = isReady ?? (Completer()..complete()) {
    _isReady.future.then((value) => _checkAndSendNext()).ignore();
  }

  Future<OUT> enqueueRequest<OUT>(FutureOr<OUT> Function() request) {
    if (_disposed) {
      throw StateError("RequestQueue disposed");
    }
    final Completer<OUT> completer = Completer();
    _requests.add((data: request, completer: completer));
    if (!_isSending) {
      unawaited(_checkAndSendNext());
    }
    return completer.future;
  }

  Future<void> _checkAndSendNext() async {
    if (_isReady.isCompleted && _requests.isNotEmpty && !_isSending && !_disposed) {
      await _sendNext();
    }
  }

  Future<void> _sendNext() async {
    try {
      if (_requests.isEmpty || _disposed) {
        _isSending = false;
        return;
      }
      _isSending = true;
      final (data: request, completer: completer) = _requests.removeFirst();
      _inFlight = completer;
      Timer? timer;

      try {
        final inFlightTimeout = this.inFlightTimeout;
        if (inFlightTimeout != null) {
          timer = Timer(inFlightTimeout, () {
            dispose(error: TimeoutException("Operation timed out", inFlightTimeout));
          });
        }

        final result = await Future.any([Future.sync(request), completer.future]);
        completer.completeIfPending(result);
      } catch (e, stack) {
        if (!completer.isCompleted) completer.completeError(e, stack);
      } finally {
        timer?.cancel();
        _inFlight = null;
      }
    } catch (e) {
      // ignore: avoid_print
      print("MessageQueue: Error fetching request with queue removeFirst");
    }
    await _sendNext();
  }

  void dispose({Object? error}) {
    if (_disposed) {
      return;
    }
    try {
      _disposed = true;
      _isSending = false;
      final cancellation = error ?? StateError("RequestQueue disposed");
      _inFlight?.completeErrorIfPending(cancellation);

      _isReady.completeErrorIfPending(
        cancellation,
      );
      while (_requests.isNotEmpty) {
        final req = _requests.removeFirst();

        req.completer.completeErrorIfPending(
          error ?? StateError("Pending Request Canceled | RequestQueue disposed"),
        );
      }
    } catch (e) {
      // ignore: avoid_print
      print("MessageQueue: Error disposing request queue $e");
    }
  }
}
