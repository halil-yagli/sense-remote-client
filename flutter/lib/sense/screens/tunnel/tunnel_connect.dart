// Sense Remote (Sürüm 12, #164, ST 7): the connecting cards of the TCP tunnel window.
import '../session/layers/connect_cards.dart';
/// Sense Remote (Sürüm 12, #164): the connecting cards of the tunnel window. RustDesk opens
/// the connection only when a program uses a tunnel, so no "Bağlanılıyor" card at start or on
/// reconnect; password, 2-step code and error cards still come when a connection is tried.
class SenseTunnelConnectHost implements SenseConnectHost {
  SenseTunnelConnectHost(this.inner);

  final SenseConnectHost inner;

  @override
  String get peerName => inner.peerName;

  @override
  bool get connected => inner.connected;

  @override
  bool get layerOwnsScreen => true;

  @override
  int get step => inner.step;

  @override
  bool get trustAvailable => inner.trustAvailable;

  @override
  Future<bool> remembered() => inner.remembered();

  @override
  void login(String password, bool remember) => inner.login(password, remember);

  @override
  void send2fa(String code, bool trust) => inner.send2fa(code, trust);

  @override
  void retry() => inner.retry();

  // Sense Remote (Sürüm 12, KQ): busy / offline card details from the panel.
  @override
  Future<SensePanelInfo?> panelInfo() => inner.panelInfo();

  @override
  void close() => inner.close();
}
