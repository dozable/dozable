// core/state — The page's one state object (every module shares this one export).


export const state = {
  csrf: null,
  expiresAt: null,
  view: 'overview',
  param: null,
  session: null,           // 593: #/sandbox/NAME/SESSION
  sbx: null,               // 593: the shown sandbox's {name, d, net, accounts}
  opsSeenAt: Date.now(),   // 593: a failure that ended after this is unacknowledged (the Operations badge)
  opsFilter: '',
  imagesMode: 'table',     // 593: Images › Table | Lineage
  overview: null,
  /// 641: the last accounts list read (the nav's badge, on hello, an accounts change, an account action's end).
  accounts: null,
  activity: [],
  ops: new Map(),
  es: null,
  renewTimer: null,
  deniedOnly: false,
  signedOut: false,
  metricsFilter: { image: '', days: '', steps: false },
  settings: null,          // 591: {report, byKey} from GET /api/v1/settings
  recipe: null,            // 669: #/recipes[/V/P] — '' the Recipes page, 'V/P' one recipe's page; null otherwise
  recipeQuery: '',         // 669: Recipes › Browse's search (#/browse)
  tr: null,                // 617: the Quick try modal's state (views/try.js)
  tryAgent: null,          // 617: the agent of #/try/AGENT
  preps: [],               // 594: the daemon's image preparations (SSE `preparations`, GET /api/v1/preparations)
  wiz: null,               // 594: the onboarding wizard's state (#/onboarding)
  serve: null,             // 606: doz serve — this browser's facts {exposure, secure, secretsAllowed, mac, device}; null on doz ui
  signup: false,           // this build has the sign-up (an official build): the setup wizard's Stay in touch step
  signupPage: '',          // else: the website's form (from the server — the page names no external URL itself)
  usageStats: null,        // an official build: the setup wizard's Usage statistics step {on, fixed, key, summary, showCommand, privacyPage}
  chatgptSignIn: true,     // this build has Dozable's own ChatGPT sign-in (a public build: false — never offered)
  sound: false,            // 667: this doz carries the sound kernel — New sandbox offers Sound
  // Chat (views/chat*.js): what the chat server last said and what this page shows of it.
  chat: {
    on: false,             // chat/status said anything but off (the sidebar's entry is shown)
    status: null,          // the last chat/status answer {state, problem?}
    active: false,         // the chat view is shown
    srv: null,             // chat/state: rooms, archived, participants {name, kind}, default_room, reactions, version
    human: null,           // the person's name in chat
    room: null,            // the room shown
    byId: new Map(),       // msg_id → the message shown (its DOM parts under _el, _body, …)
    lastSeq: 0,            // the newest seq of the room read
    firstSeq: 0,           // the oldest seq shown (older pages load above it)
    older: true,           // older messages may be left
    loadingOlder: false,
    bulk: 0,               // > 0 while a batch is drawn: the moment lines wait for its end
    atFoot: true,          // the log is scrolled to its newest message
    missed: 0,             // messages that came while it was not
    members: new Set(),    // the shown room's members (for @names)
    presence: [],          // chat/presence
    prev: new Map(),       // name → the presence state last seen
    unread: {},            // room → {n, m}: unread messages, and how many name the person
    previews: {},          // room → the last readable message
    live: 'off',           // the chat stream: off | connecting | live | reconnecting
    editing: null,         // the person's own message being edited: {id, draft, pending} (the box's text and files kept)
    pending: [],           // attachments uploaded for the next message: {id, name, type, size, url}
    uploading: 0,          // uploads under way
  },
};
