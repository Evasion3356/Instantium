local mod = get_mod("Instantium")

mod.data = {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id = "runtime_stream_warmup",
				type = "checkbox",
				default_value = true,
				tooltip = "runtime_stream_warmup_description",
			},
			{
				setting_id = "hub_caching",
				type = "checkbox",
				default_value = true,
				tooltip = "hub_caching_description",
			},
			{
				setting_id = "preload_hub",
				type = "checkbox",
				default_value = true,
				tooltip = "preload_hub_description",
			},
			{
				setting_id = "preload_psychanium",
				type = "checkbox",
				default_value = true,
				tooltip = "preload_psychanium_description",
			},
			{
				setting_id = "memory_tier_override",
				type = "dropdown",
				default_value = "auto",
				options = {
					{ text = "memory_tier_auto", value = "auto" },
					{ text = "memory_tier_conservative", value = "conservative" },
					{ text = "memory_tier_balanced", value = "balanced" },
					{ text = "memory_tier_aggressive", value = "aggressive" },
				},
				tooltip = "memory_tier_override_description",
			},
			{
				setting_id = "show_notifications",
				type = "checkbox",
				default_value = true,
				tooltip = "show_notifications_description",
			},
		}
	}
}

return mod.data
