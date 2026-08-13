export 'engine_service.dart';
export 'fairy_stockfish_service_stub.dart'
    if (dart.library.io) 'fairy_stockfish_service_io.dart'
    if (dart.library.html) 'fairy_stockfish_service_web.dart'
    if (dart.library.js_interop) 'fairy_stockfish_service_web.dart';
