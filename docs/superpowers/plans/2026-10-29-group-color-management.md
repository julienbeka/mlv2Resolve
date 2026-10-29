# Group color management correction

**Goal:** Match the user's five screenshots in all newly created projects.

**Required graph:** All timeline video clips belong to color group `All`. Group Pre Clip is P3-D60/Linear → DWG/DaVinci Intermediate, tone/gamut mapping None, forward/inverse OOTF off. Conversion Group Post Clip is DWG/Intermediate → Rec.709/Rec.709-A, DaVinci tone mapping, adaptation 9, gamut mapping None. Kodak Group Post Clip is DWG/Intermediate → Rec.709/Cineon Film Log (None mapping), the built-in `Film Looks/Rec709 Kodak 2383 D60.cube` LUT, then Rec.709/Rec.709 → Rec.709/Rec.709-A with DaVinci tone mapping. Both choices have zero timeline nodes. Clip Gyroflow stays on the clip.

**Architecture:** Import a portable DRT containing one temporary placeholder clip linked to All and its pre/post grades, then import a separate empty timeline. Resolve's group graph ApplyGradeFromDRX refused the grade, so the native group model supplies initialization instead. Assign every appended video item to All before removing the exact temporary timeline/media objects. Bind the installed built-in LUT at runtime; distribute no LUT data. Apply this only to new projects; preserve existing grading.

**Tasks:**
- [x] Establish group/node-count and script execution regression tests.
- [x] Generate portable group grades and empty timeline; validate by Resolve import and re-export.
- [x] Update Lua creation, fixtures, Swift resource selection and help/documentation.
- [x] Verify both choices, every timeline clip's membership, no timeline nodes, CST parameter round trips and untouched existing projects.
- [x] Run full test suite, review and build the updated app.

**Validation:** 281 Swift tests, 11 optional tests skipped, zero failures. Additional live test in Resolve Studio 21.1.1 passed for both populated color choices (25 fps) and an empty conversion timeline (29.97 fps), including save/reopen. Read-only review identified incorrect serialized endpoint references in an experimental model; native endpoint descriptors and node IDs were restored and are covered by regression assertions. Final review found no blocking issue. Initial build 0.2.4 (107) compiled and signature verified; user requested publication as 0.2.5 (local build 108). UPDLV restored; thirteen temporary validation projects removed.

**Source capture:** User UPDLV saved/exported locally to build/diagnostics/group-color/user-before.drp. It already contains All/42 clips, pre 1, conversion post 1 and timeline 0. Source user project is not modified by validation; separate copies are used.
