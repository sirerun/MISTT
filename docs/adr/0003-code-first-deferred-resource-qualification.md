# ADR0003: code candidates before resource qualification

Status: Accepted owner instruction,2026-10-04.

Implement the requested Go/DGX/native/release source now while CPU/memory-heavy builds/tests/model/hardware checks wait until later. This changes dispatch order, not readiness or release authority. T2.27 permits speculative source candidates against the existing paired contract; actual native clock/closure and model budgets remain unqualified and may require code corrections after measurement. No fixture passes or source review establish a working installed app. Preserve all verification,independent review,required CI,merge,landing,release and local-install gates.
