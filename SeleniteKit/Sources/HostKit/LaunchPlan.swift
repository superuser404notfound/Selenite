public enum LaunchPlan: Equatable, Sendable {
    case launch, resume, quitThenLaunch

    /// Sunshine reports the running app id in `currentgame` (0 when idle). Resuming another app
    /// would stream the wrong game, so that case quits it first.
    public static func decide(currentGame: Int, appID: Int) -> LaunchPlan {
        currentGame == 0 ? .launch : (currentGame == appID ? .resume : .quitThenLaunch)
    }
}
