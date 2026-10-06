# DM mode (design notes — not yet scheduled)

Goal: a tabletop pack where players see the "player view" by default, and hidden layers
(traps, secret doors, DM notes) appear only when unlocked.

## Options considered

### 1. Two packs: public player pack + private DM pack (recommended starting point)

- The DM keeps the full pack in a **private** GitHub repo (free) and publishes a
  **public** player pack with secret layers removed.
- The DM's app signs in to GitHub and installs the private pack; players install the
  public one.
- "Revealing" something = the DM moves it to the public pack and bumps the version.

Pros: no cryptography, nothing secret ever leaves the private repo, no risk of losing
data to a forgotten passphrase (GitHub keeps the history).
Cons: needs GitHub sign-in for the DM; reveals happen per pack update, not live.

A small tool can generate the player pack from the DM pack automatically
(drop every layer/marker tagged `"visibility": "dm"`).

### 2. Encrypted layers in a single public pack

- Secret layers are stored as AES-256-GCM ciphertext, keyed by a passphrase
  (PBKDF2/Argon2). The DM shares the passphrase — or a per-layer key — to unlock.
- Allows per-layer reveals mid-session by sharing a key.

Pros: one repo, live reveals.
Cons: if the DM loses the passphrase and the plaintext, the content is gone. That's
why the DM's source of truth should stay unencrypted somewhere private (back to option 1),
with encryption only as the publishing step.

### 3. Hash-only verification

Storing only a hash proves a passphrase is correct but doesn't *hide* anything — the
secret content would still have to be stored somewhere. Rejected.

## Decision

Start with option 1. Add option 2 later as an optional "publish with locked layers"
step in a pack-building tool, never as the only copy of the data.
