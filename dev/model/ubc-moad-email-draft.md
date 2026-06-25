# Draft email — UBC-MOAD / SalishSeaCast tidal-current constituents

**To:** SalishSeaCast / UBC-MOAD group (Mesoscale Ocean & Atmospheric Dynamics,
EOAS, UBC — PI Prof. Susan Allen). Find a current contact on
<https://salishsea.eos.ubc.ca/> / the SalishSeaCast GitHub org.

**Subject:** Request: gridded tidal-current harmonic constituents from SalishSeaCast

---

Hi SalishSeaCast team,

I'm building a small, free, **fully offline** tidal-current planning app for
sailors in the Salish Sea (iPad at the helm, no cell signal on the water). Today
it uses the Dewey *Salish Sea Tidal Current Atlas*, but that atlas only charts
the main navigable passages — sheltered bays like Bellingham, Padilla, and parts
of the inner Skagit have no current data at all. Your NEMO model clearly resolves
those areas (I confirmed surface currents in the inner Bellingham Bay cells via
your ERDDAP green-hindcast dataset), so I'd love to use SalishSeaCast to fill
those gaps.

For an offline app the natural approach is **harmonic prediction on-device**:
bundle a small grid of tidal constituents and synthesize the current at any time
and place locally (no streaming). I see from your docs that you already run
harmonic analysis (`tidetools.fittit`, t_tide, the tidal-ellipse tooling) on the
model output for validation — so you may already have exactly what I need.

**Would you be able to share a gridded set of the depth-averaged (or
near-surface) tidal-current harmonic constituents** over the model domain? Ideally
the major constituents (M2, S2, N2, K2, K1, O1, P1, Q1 — more is welcome), as
either:
- amplitude + Greenwich phase for the U (east) and V (north) components, or
- tidal-ellipse parameters (semi-major/minor axis, inclination, phase),

on the model grid (or any subset/format that's easy for you). Even a single
NetCDF would save us re-deriving it from ~20 years of hourly fields.

A couple of questions if you have a moment:
1. Is such a constituent product already available to download, or would it need
   a one-off run of your existing analysis?
2. How well does the model resolve currents in the shallow sheltered bays
   (Bellingham/Padilla)? We'd want to be honest about accuracy there.

I understand the model results are Apache-2.0; the app will **credit
SalishSeaCast / UBC-MOAD prominently** and include the license/attribution, and
I'm happy to share what we build. Glad to hop on a call or adapt to whatever
format is least work for you.

Thanks very much for making this data open — it's a wonderful resource.

Best regards,
Bryan Guenther
[contact / app link]

---

## Why this ask (context for us, not the email)

The DIY alternative — pulling the hindcast and running `utide` ourselves — is
viable but painful: ERDDAP single-point extraction is ~20 min/point (the green
3-D dataset is chunked by day), and the full grid is ~TB-scale to download. MOAD
already computes the constituents, so a direct handoff collapses the whole
acquire→analyse stage. See `model-currents-plan.md` for the full pipeline if we
end up doing it ourselves.
