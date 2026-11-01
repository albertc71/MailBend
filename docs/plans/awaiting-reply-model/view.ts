type State = { phase: string; result: string };
export const title = "Awaiting-reply evidence";
export const state = (v: State) => v.phase === "Done" ? v.result : v.phase === "Read" ? "Read bounded evidence" : "Classify evidence";
const labels: Record<string, string> = { Observe: "read finishes or is incomplete", Classify: "evaluate exact reply evidence", Done: "result remains read-only" };
export const step = (action: string) => labels[action] ?? action;
