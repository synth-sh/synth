pub const blocked = "blocked by hook";
pub const stopped = "stopped by hook";
pub const failure = "hook failed: {s}";
pub const named_failure = "{s} " ++ failure;
pub const join_lines = "{s}\n{s}";
const review_required = "Hooks need review";
pub const review_notice = review_required ++ ". Use /hooks review or synth hooks review; trust or disable each reviewed id.";
pub const observation_needs_review = review_required ++ "; an observation handler was not executed";
