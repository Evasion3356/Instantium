return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Instantium` encountered an error loading the Darktide Mod Framework.")

		new_mod("Instantium", {
			mod_script       = "Instantium/scripts/mods/Instantium/Instantium",
			mod_data         = "Instantium/scripts/mods/Instantium/Instantium_data",
			mod_localization = "Instantium/scripts/mods/Instantium/Instantium_localization",
		})
	end,
	packages = {},
	allow_rehooking = true,
	version = "0.1.0",
}
