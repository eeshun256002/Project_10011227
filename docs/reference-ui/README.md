# Reference UI evidence

Captured 2026-09-12 from https://take-margin-40556501.figma.site/ using headless Chrome through Playwright, at a 1440 x 1000 viewport. Text files contain visible screen text; PNGs preserve selected layouts. These are prototype observations, not acceptance tests of the Flutter app or a backend.

The published bundle inspected was `/assets/index-CJcsCdpW.js`, SHA-256 `65D5B02B8659F257995D6492515FA252943564B2D8259FD5CFB1FB788DEF7034`. It was inspected in a temporary directory and is not vendored into the app.

Browser navigation covered role selection, client onboarding/home/booking/report/status/history/profile and driver dashboard/job detail/map/profile. Some scripted navigation initially used incorrect accessible names; affected screens were subsequently opened with corrected locators or fresh navigation. This was not an exhaustive test of every control.

Additional source observations: client onboarding changes screen state; photo capture toggles a boolean; the map is SVG; ETA text is fixed; driver progression changes local React state; several profile action handlers are empty. In the driver dashboard, REQ-002 and REQ-005 appear both in assigned jobs and the nearby unassigned list.

No real account signup, OTP, payment, collection or external message was performed. Sample names/contact details visible in these captures belong to the reference's explicitly illustrative dataset and must not be seeded as real users.
