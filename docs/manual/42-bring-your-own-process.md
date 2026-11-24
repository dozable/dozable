# Bring your own process: a worked example

Dozable does not come with a process. It gives you the parts — a workspace with a brief, a room, agents, units of work
(runs) and a journal for each, lessons that carry into the next — and you decide how they are used. This page walks
through one real shape of process from start to finish: **draft → render a still → review → revise**, over three units of
work, with two agents in one room and you deciding. Then it shows how to map a workflow you already have onto the same
parts.

Read [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md) for what each command does; this page shows
them working together.

**On this page:** [The set-up](#the-set-up) · [The process, in the brief](#the-process-in-the-brief) ·
[The first unit of work](#the-first-unit-of-work) · [Finishing and the lesson](#finishing-and-the-lesson) ·
[The second and third](#the-second-and-third-units-of-work) · [Reading it afterwards](#reading-it-afterwards) ·
[Your own workflow](#mapping-your-own-workflow)

## The set-up

The work: a short promotional video made with Remotion, one scene per unit of work. Two workers do it: **bot1** drafts
a scene and renders a still of it; **bot2** reviews the still against criteria you set. You have no manager here — you
drive, and you decide.

```bash
doz chat on --name ada                                     # workers talk in the room, so chat must be on
doz workspace new promo --preset remotion-video --prompt-file ~/video/promo/BRIEF.md --folder ~/video/promo \
    --worker "Draft each scene and render a still of it" --worker "Review each still against the criteria" --dry-run
```

The dry run says what it would make — the workspace, its room `promo`, two declared workers in micro VMs (the preset),
the standard network and `remotion.media` — and anything that would be refused. Then, in this order — make it, open the
first unit of work and set what "done" means, start the workers, grant them — so no worker ever looks at a unit of work
with no criteria:

```bash
doz workspace new promo --preset remotion-video --prompt-file ~/video/promo/BRIEF.md --folder ~/video/promo \
    --worker "Draft each scene and render a still of it" --worker "Review each still against the criteria"
doz workspace run promo --no-start   # the first unit of work open, its goal (the brief) posted; nothing started yet
doz workspace journal promo add criterion …   # what "done" means, one entry each (The first unit of work, below)
doz workspace start promo            # bot1 and bot2 started, into the open unit of work
doz grant bot1 reviewer --in promo   # both may write the journal, attach evidence and propose lessons
doz grant bot2 reviewer --in promo
```

A declared worker becomes an agent of the workspace when it starts, so it is granted right after the start (`doz grant`
before it refuses: the workspace has no agent of that name yet). Workers may read the journal from the start; writing
needs the grant (`reviewer` is the usual one — [What agents may write](41-runs-the-journal-and-lessons.md#what-agents-may-write)).
An entry written in the moment before it is refused with exit 4, naming `journal.write`, and the agent tries again once
you have granted it — nothing is lost.

**The network.** `remotion-video` gives its micro VMs the standard network and `remotion.media`, where a render first
downloads Remotion's own browser. Anything else a composition fetches (a web font, a remote image) is refused until you
allow it — look, then allow exactly what it shows:

```bash
doz workspace show promo --network          # each agent's refusals, with the command that allows each
doz net allow promo-bot1 site:fonts.example.com
```

## The process, in the brief

The process is prose in the brief. Every agent reads it in the room at the start of each unit of work, so it is the one
place to say who does what, in which order, and what each step writes in the journal:

```markdown
# Promo video

Make a 30-second promotional video in /workspace, with Remotion. Each unit of work makes ONE scene; its goal names
the scene. With no goal, make scene 1, the title card.

The process, every unit of work:
1. bot1 writes a `task` entry for the scene, drafts it, renders a still (`npx remotion still`), attaches the still
   to a `note` entry and posts it in the room for bot2.
2. bot2 reviews the still against each `criterion` entry of this unit of work: one `review` entry per criterion
   (met yes, no or partly), and a `finding` for each problem.
3. If any criterion is not met, bot1 revises and renders again, and bot2 reviews again.
4. When every criterion is met, bot2 writes the `outcome` entry: accepted.
5. If something you learnt would help the next scene, propose it as a lesson.
Ask ada (in the room) when a choice is a matter of taste.
```

Each worker was also told its own task when it was declared; the brief says how the two fit together.

## The first unit of work

You set what "done" means for this scene — one `criterion` entry each, added in the set-up above between the run and
the start, so they are there when the workers read the unit of work:

```bash
doz workspace journal promo add criterion "The title reads at phone size" --data '{"id":"c1"}'
doz workspace journal promo add criterion "The logo is on screen for the last second" --data '{"id":"c2"}'
```

**bot1** (inside its micro VM, with `dozchat`) claims the work, drafts, renders and hands over:

```bash
dozchat journal add task "Scene 1: the title card"
npx remotion still src/index.ts Scene1 out/scene1.png
dozchat journal add note "draft 1 rendered" --attach /workspace/out/scene1.png
dozchat file send promo /workspace/out/scene1.png "Scene 1, draft 1 — ready for review"
```

A render can be long. An agent running it in its own session has no limit. If you run one yourself from the Mac,
`doz exec` stops after 120 s unless you pass `--timeout`, so start it in the background instead:

```bash
doz run promo-bot1 -d --session render -- npx remotion still src/index.ts Scene1 out/scene1.png
doz sessions screen promo-bot1 render     # how it is going
```

**A matter of taste: an Ask.** bot1 is unsure of the title's colour and asks you rather than guessing:

```bash
dozchat ask promo "Title colour?" --option a=Amber --option t=Teal
```

The Ask appears in the room as a card. Answer it there (pick **Amber**, then **Answer**), or from a terminal:

```bash
doz chat asks                  # the open asks, each with its short number
doz chat decide promo 4 a      # #4, option a
```

bot1 hears the decision (`dozchat ask-show promo #4 --wait 60` gives it as JSON) and goes on. An Ask nobody answers
expires — in 24 hours unless it says sooner — and the answer is then decline, so nothing waits for ever.

**bot2** reviews the still against each criterion:

```bash
dozchat journal add review "c1 not met: the title is too small on a phone" --data '{"criterion":"c1","met":"no"}'
dozchat journal add finding "the title is 48 px at 1080 wide" --data '{"severity":"medium"}'
dozchat journal add review "c2 met" --data '{"criterion":"c2","met":"yes"}'
dozchat send promo "@bot1 c1 not met — see the finding"
```

bot1 revises, renders draft 2 and attaches it as before; bot2 reviews again — and this time it also proposes the lesson
it learnt, then records the outcome:

```bash
dozchat journal add review "c1 met" --data '{"criterion":"c1","met":"yes"}'
dozchat propose --addendum "Check the title at phone size (1080 wide) before asking for a review"
dozchat journal add outcome "accepted" --data '{"value":"accepted"}'
```

You do not have to watch it happen. From your terminal, wait for the outcome and read the journal:

```bash
doz workspace wait promo --for journal.outcome --timeout 3600   # returns once an outcome entry is written (124 at the timeout)
doz workspace journal promo                                     # the unit of work's entries, in order
```

## Finishing and the lesson

```bash
doz workspace finish promo --yes
```

Finish closes the unit of work: its room is closed to new messages, the workers' sessions end with their conversations
kept, and its evidence is archived in the store — the room's messages, each agent's conversation and last screen, the
journal and the stills attached to it.

bot2's proposal waits as an Ask in the room: "Apply this lesson to the work description of promo?". Answer **Apply**
there, or in a terminal:

```bash
doz workspace proposals promo                    # the open proposal, with its id
doz workspace decide promo pr-1a2b3c4d apply
```

You can also propose one yourself, from what you saw: `doz workspace retro promo --propose --addendum "…"`. A lesson
applied becomes an addendum of the work description.

## The second and third units of work

```bash
doz workspace run promo "Scene 2: the product shot"
```

`run` opens the next unit of work and starts bot1 and bot2 again, in their own conversations. Its opening message in the
room is the brief, then **Lessons to apply:** with the lesson from scene 1, then **This run's goal: Scene 2: the product
shot**. So bot1 checks the title at phone size before it asks for a review, without anyone saying so again.

Set this scene's criteria, and the loop runs as before: task, still, review, revise, outcome. Finish it, decide any new
lesson, and the third is the same:

```bash
doz workspace journal promo add criterion "The product fills a third of the frame" --data '{"id":"c1"}'
doz workspace finish promo --yes
doz workspace run promo "Scene 3: the call to action"
```

Each unit of work carries every lesson approved before it. `doz workspace run promo … --json` says how many it carried
(`lessons`).

## Reading it afterwards

```bash
doz workspace runs promo                          # the three units of work: when (local time), how long, the archive, the totals
doz workspace journal promo 2026-11-24-1          # the first one's journal, from its archive
doz workspace journal promo 2026-11-24-1 --json   # …as JSON, each entry's time in UTC
doz chat read promo --since 1d                    # the room's conversation
doz workspace doc promo                           # the brief and its addenda: the lessons, each with the run it came from
```

A journal is the record of what happened, in order and by whom: each review against its criterion, each finding, each
draft's still with its hash, the outcome. Nothing in it is edited; a correction is a new entry that supersedes the old.

## Mapping your own workflow

Dozable imposes no process: the same parts fit the one you already have. Write it in the brief, as above, and decide
which journal kinds stand for its steps.

| in your workflow | in Dozable |
|---|---|
| a ticket or issue | a unit of work, its goal the ticket (`doz workspace run W "…" --source given`); a `task` entry with `--ref url:…` to the ticket |
| the definition of done | `criterion` entries at the start of the unit of work (`check` can hold the command your process runs; Dozable never runs it) |
| a branch and a pull request | the agent's own git, in the workspace's folder; a `note` with `--ref commit:SHA` and `--ref url:…` to the pull request |
| a code review | `review` entries against each criterion (`subject` the commit reviewed), `finding` entries for the problems |
| the tests or CI passing | a `note` with the log attached (`--attach`), or a review whose criterion is the test run |
| a sign-off | an `outcome` entry (`accepted`, `accepted-with-issues`, `rejected`), or an Ask to you in the room |
| a retrospective | `doz workspace retro W --propose --addendum "…"`, decided by you; applied lessons carry into every later unit of work |
| your team's own steps | your own kinds, prefixed: `acme.deploy`, `acme.release-note` |

Who may write what is yours to grant: a reviewer may write the journal and propose lessons (`reviewer`), deciding lessons
is `description.decide`, opening and finishing units of work `run.open` and `run.finish` — each off for an agent until
you grant it. A manager agent can run the loop for you instead of you driving it: make it with `--manager BOT`, and grant
it what the process needs ([Workspaces](37-workspaces.md#the-manager)).

## See also

- [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md)
- [Workspaces](37-workspaces.md) and its [presets](37-workspaces.md#presets)
- [Chat](36-chat.md) — rooms and Asks
- [What the agent can do: permissions and the network](10-permissions-and-network.md)
