"""Redirect CareerMP player-to-player payments into RLS 2.8's ledger economy.

Preserve payment server authorization and original money-change reasons.
"""
from __future__ import annotations
PAYMENTS = "lua/ge/extensions/careerMPPlayerPayments.lua"
ATTRIBUTES = "lua/ge/extensions/overhaul/career/economy/playerAttributes.lua"
SAVE = "lua/ge/extensions/overhaul/career/saveSystem.lua"

def patch_overhaul_payments(client: dict[str, bytes], rls: dict[str, bytes]) -> None:
    if PAYMENTS not in client or ATTRIBUTES not in rls or SAVE not in rls:
        raise RuntimeError("Missing CareerMP payments or RLS economy source")
    attrs = rls[ATTRIBUTES].decode("utf-8")
    saves = rls[SAVE].decode("utf-8")
    for needle in ("M.addAttributes = addAttributes", "M.getAttribute = getAttribute"):
        if needle not in attrs:
            raise RuntimeError("RLS money API changed: " + needle)
    if "M.saveCurrent = saveCurrent" not in saves:
        raise RuntimeError("RLS saveCurrent API missing")

    source = client[PAYMENTS].decode("utf-8").replace("\r\n", "\n")
    marker = "-- CareerMP040 RLS economy/ledger payments"
    if marker in source:
        return
    if source.count("career_modules_playerAttributes") != 3:
        raise RuntimeError("CareerMP money module references changed")
    if source.count("career_saveSystem.saveCurrent()") != 2:
        raise RuntimeError("CareerMP payment save calls changed")
    # RLS playerAttributes posts money changes through ledgerAuthority.post().
    # Retain the transaction reason and server confirmation logic.
    source = source.replace("career_modules_playerAttributes", "overhaul_career_economy_playerAttributes")
    source = source.replace("career_saveSystem.saveCurrent()", "overhaul_career_saveSystem.saveCurrent()")
    anchor = 'local logTag = "careerMP.payments"'
    if source.count(anchor) != 1:
        raise RuntimeError("Payment module entry changed")
    source = source.replace(anchor, anchor + "\n-- CareerMP040 RLS economy/ledger payments", 1)
    client[PAYMENTS] = source.encode("utf-8")
