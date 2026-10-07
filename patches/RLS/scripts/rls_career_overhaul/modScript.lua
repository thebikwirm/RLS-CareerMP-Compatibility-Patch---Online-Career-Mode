-- BeamNG 0.39 / CareerMP bootstrap.
--
-- Stock RLS calls loadManualUnloadExtensions() here, which immediately loads every
-- extension marked "manual" before CareerMP has selected/created its local profile.
-- That starts profile-dependent systems such as BeamEats and loans too early.
--
-- For the 0.39 compatibility build, load only the extension manager. It owns the
-- readiness gate and starts the remaining RLS runtime once worldReadyState == 2,
-- a profile/path exists, and career_career reports active.

setExtensionUnloadMode("overhaul_extensionManager", "manual")
extensions.load("overhaul_extensionManager")
