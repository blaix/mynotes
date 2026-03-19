# My Notes

A web app for storing notes.

## Phase 1

A server-side gren web app in the vein of [mycomics](https://github.com/blaix/mycomics/), [myrecords](https://github.com/blaix/myrecords), etc.

- [ ] index.html file
    - [ ] using KelpUI for styling (using CDN)
    - [ ] references a `main.js` that will be built from `src/Main.gren`
- [ ] nix for server and local dev orchestration
    - [ ] flake-based. see mycomics and myrecords for reference.
    - [ ] configurable to be hosted by blaixapps (deployed via ~/homer configs).
    - [ ] ws4sql as the database. see mycomics and myrecords for reference.
    - [ ] process-compose for local dev (via `nix run .#dev` - same as mycomics and myrecords)
- [ ] Note CRUD
    - [ ] Fields: title:string, body:string
    - [ ] Note body rendered as markdown
        - [ ] using https://github.com/icidasset/markdown-gren if appropriate
        - [ ] can we get syntax highlighting for fenced code blocks? (gh-style) (does the above package help? something in Kelp for this?)
- [ ] Deploy with blaixapps
    - [ ] Add to services hosted by blaixapps in ~/homer
    - [ ] Put the entire app behind htpasswd that's already configured for the other apps (via nginx)
    - [ ] Domain: notes.blaix.com

## Phase 2

Migrate to Prettynice.
Browser tests with blaix/gren-effectful-tests

## Phase 3

Private writes, optional public reads (let me share specific note links).

## Phase 3

Open source release under AGPL
