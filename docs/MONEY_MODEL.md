# Friendship Dream — Money model v2 (decided 2026-11-17)

Status: design approved by owner, reviewed by an independent Opus reviewer. This file replaces earlier ideas about pooled profit. If anything here conflicts with PROJECT.md money sections, this file wins. Do NOT edit migrations that are already applied; add new numbered migrations.

## Business
The samiti buys land, sells it later (profit or loss), and reinvests. Rental/other income is secondary. No real money is entered yet: all current data is test data.

## Owner decisions
- R1 New members pay all back months of principal (from the samiti start month). No late fees for back months (admins enter any past late fee manually if needed). Back months are exempt from the "late / suspension" rules. A new member becomes active once his profile is approved; he does not need to pay everything first.
- R2 Profit per investment goes only to its participants, split by actual contribution (see formulas). New members never share in investments bought before they joined (their contribution is simply 0 there).
- R3 Show BOTH views: official view by contribution (capital), and an illustrative view by shares (floor(capital/share_value)). Shares view is display-only, labelled "illustrative", never used for losses or payouts. Show total profit, each member's amount, and the rounding remainder.
- R4 Capital (contributed capital) NEVER changes because of expenses. Expenses lower a member's net result / equity. UI wording: "taken from profit first, then capital".
- R5 Share transfer: a member sells his WHOLE stake (contributed capital, net result so far, and all his contributions in held investments) to a buyer (existing member or a new person with an approved profile). All other active members must consent in the app; any objection blocks it; super admin finalizes. Money between seller and buyer is outside the system. Fund total does not change. Seller becomes exited.
- Existing member as buyer: monthly deposit stays ONE monthly amount (the monthly amount is per member, not per share). Shares are recomputed from merged capital.
- Cost of one specific land (registration, tax, broker, development) is added to that investment's cost basis if at purchase, or charged only to that investment's participants by contribution if after. General overhead (bank fees, audit, software) is split among active members by equity at approval time.
- Rent/other income of an investment goes to that investment's participants by contribution. Late fees go to a separate samiti reserve (not distributed; use decided later, e.g. charity or expenses). Rounding remainders also go to the reserve.
- Payout/withdrawal: NOT built now. Reserve ledger kinds `payout` and exit rules for later (owner's rules mention 2-year minimum before exit and 3-year maturity). Do not design anything that blocks adding it.
- Suspended members still participate in investments and vote on transfers (their money is in the pool).
- Partial sale of a plot and partial share transfer: blocked in v1.

## Core concepts (per member)
- contributed_capital = approved deposits (+ transfer in − transfer out). Sets shares. Never changed by expenses or profit.
- net_result = allocated profit + income − losses − expense shares (+/- result transfers).
- equity = contributed_capital + net_result.
- committed = sum of contribution in HELD investments. free = equity − committed. A member needs free > 0 to take part in a PURCHASE (and puts in at most that much). Free MAY go below zero later through expenses, investment costs or reversals: the member then "owes the pool" (decided 2026-11-17, shown in the UI). A deposit correction may still not push a member below zero.
- total_fund = sum(equity) + reserve. invested = sum(cost of held investments incl. capitalized costs). cash = total_fund − invested >= 0.

## Data model (new migration(s); keep existing numeric money type and scale, floor to 0.01, never float)
- member_ledger(id, member_id, kind, amount, source_type, source_id, created_at). kind: capital_deposit, capital_transfer_in/out, profit, loss, income, expense, result_transfer_in/out. Append-only. Single source of truth for per-member balances. Allocations are WRITTEN at event time, never recomputed.
- allocations(id, event_type, event_id, basis capital|shares, member_id null, amount). member_id null = rounding remainder (goes to reserve). Shares-view rows are display-only and never posted to member_ledger.
- fund_reserve (late fees + remainders), readable as a view or table; append-only.
- investment_participation(id, investment_id, member_id, contribution_delta, capital_at_purchase, shares_at_purchase, reason purchase|transfer, transfer_id). Append-only. After a transfer, participation is read from this ledger, not recomputed from joined_on.
- expenses get optional investment_id.
- deposits get is_back_month boolean.
- share_transfers(id, seller_id, buyer_id, status proposed|blocked|finalized|expired, proposed_at, deadline, finalized_by, finalized_at, snapshot_capital, snapshot_result).
- transfer_consent_required(transfer_id, member_id): frozen voter list at proposal time.
- transfer_consents(transfer_id, member_id, decision consent|object, decided_at), unique(transfer_id, member_id).

## Formulas (inside each RPC, under the fund lock)
- Purchase of cost C: require sum(free_i) >= C. contribution_i = C * free_i / sum(free_i), largest-remainder rounding so contributions add up exactly to C. Also store capital_at_purchase and shares_at_purchase.
- Sale: profit = proceeds − (cost + capitalized costs), may be negative. Official: p_i = profit * contribution_i / C. Illustrative shares view: profit * shares_i / sum(shares) only if sum(shares) > 0 (no divide by zero).
- Expense E: general -> e_i = E * equity_i / sum(equity) over active members with equity > 0; investment-specific (also allowed after the plot is sold) -> E * contribution_i / C over that plot's participants. Expenses, investment costs and reversals only check cash >= 0.
- Rounding: work on the absolute value in whole cents with exact integer division. Positive totals (profit, income): floor each member amount. Negative totals (loss, expense): ceil each member amount. So the remainder R, stored as an allocation row with member_id null and posted to the reserve, is ALWAYS >= 0. Every allocation row stores weight and weight_sum so the amount can be recomputed. Largest-remainder only for purchase contributions (they must sum exactly to the cost basis).
- Reversals (income, expense): full amount, once, approved by a second admin; they post the exact opposite of the original allocation rows (same members, amounts and reserve remainder). An expense reversal is never blocked by cash or free checks.
- Home-page identity (source tables): total_fund = capital + late fees + income + profit − expenses (+ other reserve kinds such as payouts). The rounding reserve is NOT added on top: it is the part of those same events that went to the reserve.
- Snapshots use approval/commit timestamps, not the deposit month or expense date. A deposit for an earlier month approved after a purchase does not join that purchase. Same-day rule: member must be active at commit time and joined_on <= purchase date.

## Concurrency and immutability
- Every money RPC takes one fund-wide advisory lock (pg_advisory_xact_lock) and recomputes balances and writes snapshot + allocations in the same transaction.
- Triggers block UPDATE and DELETE on every money table for every role. Corrections are new reversing rows. The only allowed changes: an investment goes held -> sold once (approve_sale); a request goes pending -> approved/rejected once; a rejected purchase also rejects its cost items. joined_on is frozen once a member has ledger rows; status exited only through finalize_transfer (6D).
- finalize_transfer checks inside the lock: seller active, no pending deposits/late fees; buyer approved by two people and buyer != seller; every required voter has consented and none objected; deadline not passed; seller has no other open transfer; nothing changed since the proposal snapshot (block otherwise). Seller deposits/new allocations are frozen while a transfer is open.
- check_invariants() fails loudly (26 rules since migration 010), among them: independent cash rebuild; sum(equity)+reserve = total_fund; the home-page identity; sum(committed) = invested; contributions = cost basis per investment; 0 < contribution <= free money at purchase; cash >= 0; every allocation set sums to its event amount; each amount recomputes from its weight; reserve leftovers >= 0; reversals mirror their original; plot results only reach that plot's participants; every money row has exactly one matching approved request; capitalized costs = approved cost items; two people per decision.

## RPCs
approve_deposit, approve_expense, purchase_investment, sell_investment, record_investment_income, activate_member, propose_transfer, cast_consent, finalize_transfer, check_invariants.

## DB vs UI
DB enforces: immutability, maker != checker, cash >= 0, eligibility, all allocation math (SQL functions/views), transfer preconditions, frozen voter list, back-month exemption, RLS (members read their own data plus agreed aggregates; respect members_can_see_others). UI only: both views side by side, "illustrative" label, wording, warnings, consent screens. The UI never calculates money.

## Build order
- 6A Ledger foundation: member_ledger, allocations, reserve, invariants; every approved deposit writes a capital_deposit ledger row (and backfill existing approved test deposits); back-month flag and suspension exemption; fund_summary/member_totals read from the ledger. Existing pages keep working.
- 6B Investments and expenses on the ledger: purchase_investment with contributions, sale with profit allocation, investment-specific costs and income, general expense allocation by equity, late fees to reserve. Rewire the Phase 5 screens.
- 6C Profit views: /profit with official (by contribution) and illustrative (by shares) tables, remainder row, note "Based on contributions to each investment. Shown for information; not a payout."
- 6D New members and transfers: back-month schedule for new members, propose/consent/finalize UI, exited seller, history.
After each sub-phase: tsc, build, DB and browser tests that try to break every rule, then report. Opus reviews each SQL migration.

## Historical import (Phase 7)
The sheet history is imported once from the SQL Editor (`import_history`, migration 011): deposits through the normal deposit triggers, the first land through the same `purchase_core` as approve_investment. The two-person rule is replaced by an `import_batch_id` on the imported purchase rows (check_invariants rule 27); markers `import_done` / `go_live` make a second run impossible. Details: docs/HISTORICAL_IMPORT.md.

## Payment rules (late fee, paid on time, suspension) — for later phases
Any such rule must decide only on deposits where `public.counts_for_payment_rules(d)` is true (migration 012): historical, imported and back-month deposits never count against a member. Since 012 the books are closed until the `import_done` or `go_live` marker exists (no approvals or money entries before the historical import).
