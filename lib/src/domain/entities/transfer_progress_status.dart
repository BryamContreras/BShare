enum TransferProgressStatus {
  queued,
  sending,
  receiving,
  paused,
  cancelled,
  completed,
  failed,
}

extension TransferProgressStatusX on TransferProgressStatus {
  bool get isTerminal =>
      this == TransferProgressStatus.completed ||
      this == TransferProgressStatus.cancelled ||
      this == TransferProgressStatus.failed;
}
