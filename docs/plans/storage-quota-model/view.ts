type State = { phase: string; result: string };
export const title = "Read-only storage observation";
export const state = (v: State) => v.phase === "Done" ? v.result : v.phase;
const labels: Record<string, string> = {
  Gate: "check current authenticated capability",
  Observe: "validate one root and its STORAGE resource",
  Done: "keep the observation",
};
export const step = (action: string) => labels[action] ?? action;
