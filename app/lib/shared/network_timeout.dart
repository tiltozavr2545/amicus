/// Applied to every Supabase call (`.timeout(networkTimeout)`) so a stalled
/// request (e.g. sending in airplane mode) surfaces the existing error
/// message within seconds instead of leaving the UI spinning indefinitely.
const networkTimeout = Duration(seconds: 12);
