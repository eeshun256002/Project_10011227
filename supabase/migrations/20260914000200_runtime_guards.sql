-- Authorization/error guards must run at execution time. Marking an always-
-- raising helper IMMUTABLE lets the planner evaluate it in otherwise unreachable
-- CASE branches and creates false lint errors while preparing guarded queries.
alter function wm.fail(text) volatile;
alter function wm.require_actor() volatile;
