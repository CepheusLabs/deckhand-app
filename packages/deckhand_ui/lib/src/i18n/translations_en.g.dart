///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import
// dart format off

part of 'translations.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element
class Translations with BaseTranslations<AppLocale, Translations> {
	/// Returns the current translations of the given [context].
	///
	/// Usage:
	/// final t = Translations.of(context);
	static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

	/// You can call this constructor and build your own translation instance of this locale.
	/// Constructing via the enum [AppLocale.build] is preferred.
	Translations({Map<String, Node>? overrides, PluralResolver? cardinalResolver, PluralResolver? ordinalResolver, TranslationMetadata<AppLocale, Translations>? meta})
		: assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
		  $meta = meta ?? TranslationMetadata(
		    locale: AppLocale.en,
		    overrides: overrides ?? {},
		    cardinalResolver: cardinalResolver,
		    ordinalResolver: ordinalResolver,
		  ) {
		$meta.setFlatMapFunction(_flatMapFunction);
	}

	/// Metadata for the translations of <en>.
	@override final TranslationMetadata<AppLocale, Translations> $meta;

	/// Access flat map
	dynamic operator[](String key) => $meta.getTranslation(key);

	late final Translations _root = this; // ignore: unused_field

	Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

	// Translations
	late final TranslationsWelcomeEn welcome = TranslationsWelcomeEn.internal(_root);
	late final TranslationsPickPrinterEn pick_printer = TranslationsPickPrinterEn.internal(_root);
	late final TranslationsConnectEn connect = TranslationsConnectEn.internal(_root);
	late final TranslationsVerifyEn verify = TranslationsVerifyEn.internal(_root);
	late final TranslationsChoosePathEn choose_path = TranslationsChoosePathEn.internal(_root);
	late final TranslationsErrorsEn errors = TranslationsErrorsEn.internal(_root);
	late final TranslationsFirmwareEn firmware = TranslationsFirmwareEn.internal(_root);
	late final TranslationsWebuiEn webui = TranslationsWebuiEn.internal(_root);
	late final TranslationsKiauhEn kiauh = TranslationsKiauhEn.internal(_root);
	late final TranslationsScreenChoiceEn screen_choice = TranslationsScreenChoiceEn.internal(_root);
	late final TranslationsServicesEn services = TranslationsServicesEn.internal(_root);
	late final TranslationsFilesEn files = TranslationsFilesEn.internal(_root);
	late final TranslationsHardeningEn hardening = TranslationsHardeningEn.internal(_root);
	late final TranslationsFlashTargetEn flash_target = TranslationsFlashTargetEn.internal(_root);
	late final TranslationsChooseOsEn choose_os = TranslationsChooseOsEn.internal(_root);
	late final TranslationsFlashConfirmEn flash_confirm = TranslationsFlashConfirmEn.internal(_root);
	late final TranslationsFlashProgressEn flash_progress = TranslationsFlashProgressEn.internal(_root);
	late final TranslationsFirstBootEn first_boot = TranslationsFirstBootEn.internal(_root);
	late final TranslationsFirstBootSetupEn first_boot_setup = TranslationsFirstBootSetupEn.internal(_root);
	late final TranslationsReviewEn review = TranslationsReviewEn.internal(_root);
	late final TranslationsProgressEn progress = TranslationsProgressEn.internal(_root);
	late final TranslationsDoneEn done = TranslationsDoneEn.internal(_root);
	late final TranslationsSettingsEn settings = TranslationsSettingsEn.internal(_root);
	late final TranslationsCommonEn common = TranslationsCommonEn.internal(_root);
}

// Path: welcome
class TranslationsWelcomeEn {
	TranslationsWelcomeEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Welcome to Deckhand'
	String get title => 'Welcome to Deckhand';

	/// en: 'Flash, set up, and maintain Klipper-based printers. This wizard walks you through replacing vendor firmware with Kalico or Klipper end-to- end, either in place on your existing OS or on a fresh install. '
	String get helper => 'Flash, set up, and maintain Klipper-based printers. This wizard walks\nyou through replacing vendor firmware with Kalico or Klipper end-to-\nend, either in place on your existing OS or on a fresh install.\n';

	/// en: 'Start'
	String get action_start => 'Start';

	/// en: 'Settings'
	String get action_settings => 'Settings';

	late final TranslationsWelcomeCardFirstTimeEn card_first_time = TranslationsWelcomeCardFirstTimeEn.internal(_root);
	late final TranslationsWelcomeCardSafetyEn card_safety = TranslationsWelcomeCardSafetyEn.internal(_root);
}

// Path: pick_printer
class TranslationsPickPrinterEn {
	TranslationsPickPrinterEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Which printer are you setting up?'
	String get title => 'Which printer are you setting up?';

	/// en: 'Deckhand supports these printers. Pick yours - we use that choice to load the right profile before anything else. '
	String get helper => 'Deckhand supports these printers. Pick yours - we use that choice to\nload the right profile before anything else.\n';

	/// en: 'Show stub profiles'
	String get show_stubs => 'Show stub profiles';

	/// en: 'My printer isn't here →'
	String get no_printer_link => 'My printer isn\'t here →';

	/// en: 'Continue'
	String get action_continue => 'Continue';

	/// en: 'Back'
	String get action_back => 'Back';

	/// en: 'Failed to load printer registry: $error'
	String registry_error({required Object error}) => 'Failed to load printer registry: ${error}';
}

// Path: connect
class TranslationsConnectEn {
	TranslationsConnectEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Connect to your printer'
	String get title => 'Connect to your printer';

	/// en: 'Deckhand scans your LAN two ways: mDNS for printers that advertise Moonraker, and a TCP sweep of port 7125 across your local subnet. Each host is probed to see whether it matches your selected profile - confirmed matches surface at the top. '
	String get helper => 'Deckhand scans your LAN two ways: mDNS for printers that advertise\nMoonraker, and a TCP sweep of port 7125 across your local subnet.\nEach host is probed to see whether it matches your selected\nprofile - confirmed matches surface at the top.\n';

	/// en: 'Host or IP'
	String get field_host => 'Host or IP';

	/// en: 'e.g. 192.168.1.50 or mkspi.local'
	String get hint_host => 'e.g. 192.168.1.50 or mkspi.local';

	/// en: 'Connect'
	String get action_connect => 'Connect';

	/// en: 'Connecting…'
	String get action_connecting => 'Connecting…';

	/// en: 'Rescan'
	String get action_rescan => 'Rescan';

	/// en: 'First time connecting to this printer'
	String get host_key_title_new => 'First time connecting to this printer';

	/// en: 'Deckhand has not seen this printer before. Compare the fingerprint below against what the printer reports locally. If it matches, accept it and Deckhand will remember it for future connections. '
	String get host_key_body_new => 'Deckhand has not seen this printer before. Compare the fingerprint\nbelow against what the printer reports locally. If it matches,\naccept it and Deckhand will remember it for future connections.\n';

	/// en: 'Accept and connect'
	String get host_key_confirm_new => 'Accept and connect';

	/// en: 'This printer's SSH fingerprint changed'
	String get host_key_title_mismatch => 'This printer\'s SSH fingerprint changed';

	/// en: 'The fingerprint presented by this printer does not match the one Deckhand saved previously. This can happen if you reinstalled the printer's OS, but it can also indicate something is intercepting the connection. If you expected this change, clear the pinned fingerprint in Settings and try again. '
	String get host_key_body_mismatch => 'The fingerprint presented by this printer does not match the one\nDeckhand saved previously. This can happen if you reinstalled the\nprinter\'s OS, but it can also indicate something is intercepting\nthe connection. If you expected this change, clear the pinned\nfingerprint in Settings and try again.\n';

	/// en: 'Found on your network'
	String get section_discovered => 'Found on your network';

	/// en: 'Or enter manually'
	String get section_manual => 'Or enter manually';

	/// en: 'Nothing responded on port 7125 across your local subnet, and no Moonraker mDNS advertisements were seen either. Your printer may be on a different VLAN, behind a firewall, or using a non-default port - enter the IP/hostname below. '
	String get empty_state => 'Nothing responded on port 7125 across your local subnet, and no\nMoonraker mDNS advertisements were seen either. Your printer may be\non a different VLAN, behind a firewall, or using a non-default\nport - enter the IP/hostname below.\n';

	/// en: 'Looks like your $profile'
	String match_confirmed({required Object profile}) => 'Looks like your ${profile}';

	/// en: 'Probably your $profile'
	String match_probable({required Object profile}) => 'Probably your ${profile}';

	/// en: 'Does not look like $profile'
	String match_miss({required Object profile}) => 'Does not look like ${profile}';

	/// en: 'Checking...'
	String get match_checking => 'Checking...';

	/// en: 'installed by Deckhand as $profileId'
	String reason_marker_with_id({required Object profileId}) => 'installed by Deckhand as ${profileId}';

	/// en: 'Deckhand marker file present'
	String get reason_marker_generic => 'Deckhand marker file present';

	/// en: 'Klipper config uses `$object`'
	String reason_object({required Object object}) => 'Klipper config uses `${object}`';

	/// en: 'hostname `$hostname` matches profile'
	String reason_hostname({required Object hostname}) => 'hostname `${hostname}` matches profile';

	/// en: 'confirmed match for $profile$reason'
	String semantics_confirmed({required Object profile, required Object reason}) => 'confirmed match for ${profile}${reason}';

	/// en: 'probable match for $profile$reason'
	String semantics_probable({required Object profile, required Object reason}) => 'probable match for ${profile}${reason}';

	/// en: 'does not match $profile'
	String semantics_miss({required Object profile}) => 'does not match ${profile}';

	/// en: 'match status unknown'
	String get semantics_unknown => 'match status unknown';
}

// Path: verify
class TranslationsVerifyEn {
	TranslationsVerifyEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Verify your printer'
	String get title => 'Verify your printer';

	/// en: 'We'll run a few quick checks against your connected printer to confirm this profile matches. Warnings don't block the wizard - you can always proceed. '
	String get helper => 'We\'ll run a few quick checks against your connected printer to\nconfirm this profile matches. Warnings don\'t block the wizard - you\ncan always proceed.\n';

	/// en: 'Continue'
	String get action_continue => 'Continue';

	/// en: 'Back'
	String get action_back => 'Back';
}

// Path: choose_path
class TranslationsChoosePathEn {
	TranslationsChoosePathEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Which path do you want to take?'
	String get title => 'Which path do you want to take?';

	/// en: 'Choose whether to reuse the OS already on your printer or wipe the eMMC and install a fresh Armbian image. Both lead to the same final state (Kalico or Klipper + your chosen web UI); they differ in blast radius and in what you have to manage yourself. '
	String get helper => 'Choose whether to reuse the OS already on your printer or wipe the\neMMC and install a fresh Armbian image. Both lead to the same final\nstate (Kalico or Klipper + your chosen web UI); they differ in blast\nradius and in what you have to manage yourself.\n';

	late final TranslationsChoosePathStockEn stock = TranslationsChoosePathStockEn.internal(_root);
	late final TranslationsChoosePathFreshEn fresh = TranslationsChoosePathFreshEn.internal(_root);

	/// en: 'Continue'
	String get action_continue => 'Continue';

	/// en: 'Back'
	String get action_back => 'Back';
}

// Path: errors
class TranslationsErrorsEn {
	TranslationsErrorsEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Something went wrong'
	String get dialog_title_generic => 'Something went wrong';

	/// en: 'Retry'
	String get action_retry => 'Retry';

	/// en: 'Start over'
	String get action_start_over => 'Start over';

	/// en: 'Save debug bundle'
	String get action_save_debug_bundle => 'Save debug bundle';

	late final TranslationsErrorsSshConnectionEn ssh_connection = TranslationsErrorsSshConnectionEn.internal(_root);
	late final TranslationsErrorsSshAuthEn ssh_auth = TranslationsErrorsSshAuthEn.internal(_root);
	late final TranslationsErrorsHostKeyMismatchEn host_key_mismatch = TranslationsErrorsHostKeyMismatchEn.internal(_root);
	late final TranslationsErrorsFlashEn flash = TranslationsErrorsFlashEn.internal(_root);
	late final TranslationsErrorsDiskEnumerationEn disk_enumeration = TranslationsErrorsDiskEnumerationEn.internal(_root);
	late final TranslationsErrorsElevationRequiredEn elevation_required = TranslationsErrorsElevationRequiredEn.internal(_root);
	late final TranslationsErrorsProfileFetchEn profile_fetch = TranslationsErrorsProfileFetchEn.internal(_root);
	late final TranslationsErrorsProfileParseEn profile_parse = TranslationsErrorsProfileParseEn.internal(_root);
	late final TranslationsErrorsUpstreamFetchEn upstream_fetch = TranslationsErrorsUpstreamFetchEn.internal(_root);
	late final TranslationsErrorsSidecarStartEn sidecar_start = TranslationsErrorsSidecarStartEn.internal(_root);
	late final TranslationsErrorsSidecarRpcEn sidecar_rpc = TranslationsErrorsSidecarRpcEn.internal(_root);
}

// Path: firmware
class TranslationsFirmwareEn {
	TranslationsFirmwareEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Pick your firmware'
	String get title => 'Pick your firmware';

	/// en: 'Kalico is a community-maintained Klipper fork with weekly rebases and helpful extras (gcode_shell_command, danger_options). Mainline Klipper is upstream/master - more conservative. '
	String get helper => 'Kalico is a community-maintained Klipper fork with weekly rebases\nand helpful extras (gcode_shell_command, danger_options). Mainline\nKlipper is upstream/master - more conservative.\n';
}

// Path: webui
class TranslationsWebuiEn {
	TranslationsWebuiEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Which web interface?'
	String get title => 'Which web interface?';

	/// en: 'Web dashboards for controlling the printer from a browser. They both talk to the same backend (Moonraker), so you can install both and switch between them any time. '
	String get helper => 'Web dashboards for controlling the printer from a browser. They\nboth talk to the same backend (Moonraker), so you can install\nboth and switch between them any time.\n';

	/// en: 'Pick at least one. This step cannot be skipped.'
	String get requirement_ok => 'Pick at least one. This step cannot be skipped.';

	/// en: 'Pick at least one to continue.'
	String get requirement_missing => 'Pick at least one to continue.';
}

// Path: kiauh
class TranslationsKiauhEn {
	TranslationsKiauhEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Install KIAUH?'
	String get title => 'Install KIAUH?';
}

// Path: screen_choice
class TranslationsScreenChoiceEn {
	TranslationsScreenChoiceEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Pick a screen daemon'
	String get title => 'Pick a screen daemon';
}

// Path: services
class TranslationsServicesEn {
	TranslationsServicesEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: '$current of $total'
	String counter({required Object current, required Object total}) => '${current} of ${total}';
}

// Path: files
class TranslationsFilesEn {
	TranslationsFilesEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Leftover files'
	String get title => 'Leftover files';
}

// Path: hardening
class TranslationsHardeningEn {
	TranslationsHardeningEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Security hardening (optional)'
	String get title => 'Security hardening (optional)';
}

// Path: flash_target
class TranslationsFlashTargetEn {
	TranslationsFlashTargetEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Which disk should we flash?'
	String get title => 'Which disk should we flash?';
}

// Path: choose_os
class TranslationsChooseOsEn {
	TranslationsChooseOsEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Which OS image?'
	String get title => 'Which OS image?';
}

// Path: flash_confirm
class TranslationsFlashConfirmEn {
	TranslationsFlashConfirmEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Confirm the wipe'
	String get title => 'Confirm the wipe';
}

// Path: flash_progress
class TranslationsFlashProgressEn {
	TranslationsFlashProgressEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Writing image'
	String get title_running => 'Writing image';

	/// en: 'Flash complete'
	String get title_done => 'Flash complete';
}

// Path: first_boot
class TranslationsFirstBootEn {
	TranslationsFirstBootEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Put the eMMC back in the printer'
	String get title => 'Put the eMMC back in the printer';
}

// Path: first_boot_setup
class TranslationsFirstBootSetupEn {
	TranslationsFirstBootSetupEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'First boot setup'
	String get title => 'First boot setup';
}

// Path: review
class TranslationsReviewEn {
	TranslationsReviewEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Review your choices'
	String get title => 'Review your choices';
}

// Path: progress
class TranslationsProgressEn {
	TranslationsProgressEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Installing...'
	String get title_installing => 'Installing...';

	/// en: 'All done'
	String get title_done => 'All done';

	/// en: 'Something went wrong'
	String get title_failed => 'Something went wrong';

	/// en: 'Working...'
	String get title_working => 'Working...';

	/// en: 'Downloading image'
	String get phase_os_download => 'Downloading image';

	/// en: 'Writing image'
	String get phase_flash_disk => 'Writing image';

	/// en: 'Waiting for the printer to come back'
	String get phase_wait_for_ssh => 'Waiting for the printer to come back';

	/// en: 'Installing firmware'
	String get phase_install_firmware => 'Installing firmware';

	/// en: 'Installing Moonraker + web UI'
	String get phase_install_stack => 'Installing Moonraker + web UI';

	/// en: 'Copying Klipper extras'
	String get phase_link_extras => 'Copying Klipper extras';

	/// en: 'Installing the touchscreen UI'
	String get phase_install_screen => 'Installing the touchscreen UI';

	/// en: 'Flashing MCU firmware'
	String get phase_flash_mcus => 'Flashing MCU firmware';

	/// en: 'Cleaning up stock services'
	String get phase_apply_services => 'Cleaning up stock services';

	/// en: 'Cleaning up stock files'
	String get phase_apply_files => 'Cleaning up stock files';

	/// en: 'Backing up stock files'
	String get phase_snapshot_paths => 'Backing up stock files';

	/// en: 'Writing config'
	String get phase_write_file => 'Writing config';

	/// en: 'Marking this printer as Deckhand-managed'
	String get phase_install_marker => 'Marking this printer as Deckhand-managed';

	/// en: 'Verifying'
	String get phase_verify => 'Verifying';

	/// en: 'Running setup script'
	String get phase_script => 'Running setup script';

	/// en: 'Running remote commands'
	String get phase_ssh_commands => 'Running remote commands';

	/// en: 'Evaluating condition'
	String get phase_conditional => 'Evaluating condition';

	/// en: 'Finish'
	String get action_finish => 'Finish';

	/// en: 'Close'
	String get action_close => 'Close';

	/// en: 'Running...'
	String get action_running => 'Running...';

	/// en: 'One moment'
	String get prompt_default_title => 'One moment';

	/// en: 'Continue'
	String get prompt_default_action => 'Continue';

	/// en: 'Pick one'
	String get choose_one_default_title => 'Pick one';

	/// en: 'OK'
	String get choose_one_ok => 'OK';

	/// en: 'Pick the target disk'
	String get disk_picker_title => 'Pick the target disk';

	/// en: 'Cancel'
	String get disk_picker_cancel => 'Cancel';

	/// en: 'Use this disk'
	String get disk_picker_confirm => 'Use this disk';

	/// en: 'No removable disks found'
	String get disk_picker_no_disks_title => 'No removable disks found';

	/// en: 'Plug the printer eMMC into a USB adapter, then try again. Internal disks are dimmed here to prevent accidents. '
	String get disk_picker_no_disks_body => 'Plug the printer eMMC into a USB adapter, then try again. Internal\ndisks are dimmed here to prevent accidents.\n';

	/// en: 'Could not list disks'
	String get disk_picker_list_error_title => 'Could not list disks';

	/// en: 'Current step progress'
	String get semantics_progress_label => 'Current step progress';

	/// en: 'indeterminate'
	String get semantics_progress_indeterminate => 'indeterminate';

	/// en: '$percent percent'
	String semantics_progress_percent({required Object percent}) => '${percent} percent';

	/// en: 'Step execution log'
	String get semantics_log_label => 'Step execution log';
}

// Path: done
class TranslationsDoneEn {
	TranslationsDoneEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Setup complete'
	String get title => 'Setup complete';

	/// en: 'Next steps'
	String get next_steps => 'Next steps';
}

// Path: settings
class TranslationsSettingsEn {
	TranslationsSettingsEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Settings'
	String get title => 'Settings';

	/// en: 'Printer profiles'
	String get section_profiles => 'Printer profiles';

	/// en: 'Local profiles directory'
	String get profiles_local_dir_label => 'Local profiles directory';

	/// en: 'Point Deckhand at a checked-out copy of deckhand-builds on this machine instead of fetching main from GitHub. Useful for profile authoring. Leave empty to fetch from GitHub. '
	String get profiles_local_dir_hint => 'Point Deckhand at a checked-out copy of deckhand-builds on this\nmachine instead of fetching main from GitHub. Useful for profile\nauthoring. Leave empty to fetch from GitHub.\n';

	/// en: 'Using local dir'
	String get profiles_local_dir_active => 'Using local dir';

	/// en: 'Fetching from GitHub'
	String get profiles_local_dir_github => 'Fetching from GitHub';

	/// en: 'Pick folder...'
	String get profiles_local_dir_pick => 'Pick folder...';

	/// en: 'Clear'
	String get profiles_local_dir_clear => 'Clear';

	/// en: 'Directory not found or unreadable.'
	String get profiles_local_dir_invalid => 'Directory not found or unreadable.';
}

// Path: common
class TranslationsCommonEn {
	TranslationsCommonEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Back'
	String get action_back => 'Back';

	/// en: 'Continue'
	String get action_continue => 'Continue';

	/// en: 'Finish'
	String get action_finish => 'Finish';

	/// en: 'Cancel'
	String get action_cancel => 'Cancel';
}

// Path: welcome.card_first_time
class TranslationsWelcomeCardFirstTimeEn {
	TranslationsWelcomeCardFirstTimeEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'First time here?'
	String get title => 'First time here?';

	/// en: 'The wizard will ask which printer you have, try to reach it over SSH using known default credentials, then let you pick what you want to replace and what you want to keep. '
	String get body => 'The wizard will ask which printer you have, try to reach it over\nSSH using known default credentials, then let you pick what you\nwant to replace and what you want to keep.\n';
}

// Path: welcome.card_safety
class TranslationsWelcomeCardSafetyEn {
	TranslationsWelcomeCardSafetyEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Safety'
	String get title => 'Safety';

	/// en: 'Nothing destructive happens without explicit confirmation. Deckhand can back up your entire eMMC to an image before any firmware swap, so you always have a route back to stock. '
	String get body => 'Nothing destructive happens without explicit confirmation. Deckhand\ncan back up your entire eMMC to an image before any firmware swap,\nso you always have a route back to stock.\n';
}

// Path: choose_path.stock
class TranslationsChoosePathStockEn {
	TranslationsChoosePathStockEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Keep my current OS'
	String get title => 'Keep my current OS';

	/// en: 'Transforms your printer in place. Snapshots the stock Klipper install, then swaps in the firmware you pick. Any vendor services you don't want are disabled or removed per your selections. '
	String get body => 'Transforms your printer in place. Snapshots the stock Klipper\ninstall, then swaps in the firmware you pick. Any vendor services\nyou don\'t want are disabled or removed per your selections.\n';
}

// Path: choose_path.fresh
class TranslationsChoosePathFreshEn {
	TranslationsChoosePathFreshEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Flash a new OS'
	String get title => 'Flash a new OS';

	/// en: 'Wipes the eMMC and installs a clean Armbian image. Strongly preferred if you have an eMMC-to-USB adapter handy and want a fully known-good base. '
	String get body => 'Wipes the eMMC and installs a clean Armbian image. Strongly\npreferred if you have an eMMC-to-USB adapter handy and want a\nfully known-good base.\n';
}

// Path: errors.ssh_connection
class TranslationsErrorsSshConnectionEn {
	TranslationsErrorsSshConnectionEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Can't reach the printer'
	String get title => 'Can\'t reach the printer';
}

// Path: errors.ssh_auth
class TranslationsErrorsSshAuthEn {
	TranslationsErrorsSshAuthEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Couldn't sign in to the printer'
	String get title => 'Couldn\'t sign in to the printer';
}

// Path: errors.host_key_mismatch
class TranslationsErrorsHostKeyMismatchEn {
	TranslationsErrorsHostKeyMismatchEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Printer's SSH fingerprint changed'
	String get title => 'Printer\'s SSH fingerprint changed';
}

// Path: errors.flash
class TranslationsErrorsFlashEn {
	TranslationsErrorsFlashEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Disk flash failed'
	String get title => 'Disk flash failed';
}

// Path: errors.disk_enumeration
class TranslationsErrorsDiskEnumerationEn {
	TranslationsErrorsDiskEnumerationEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Couldn't enumerate local disks'
	String get title => 'Couldn\'t enumerate local disks';
}

// Path: errors.elevation_required
class TranslationsErrorsElevationRequiredEn {
	TranslationsErrorsElevationRequiredEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Administrator permission required'
	String get title => 'Administrator permission required';
}

// Path: errors.profile_fetch
class TranslationsErrorsProfileFetchEn {
	TranslationsErrorsProfileFetchEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Couldn't load printer profiles'
	String get title => 'Couldn\'t load printer profiles';
}

// Path: errors.profile_parse
class TranslationsErrorsProfileParseEn {
	TranslationsErrorsProfileParseEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Malformed printer profile'
	String get title => 'Malformed printer profile';
}

// Path: errors.upstream_fetch
class TranslationsErrorsUpstreamFetchEn {
	TranslationsErrorsUpstreamFetchEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Couldn't fetch an upstream component'
	String get title => 'Couldn\'t fetch an upstream component';
}

// Path: errors.sidecar_start
class TranslationsErrorsSidecarStartEn {
	TranslationsErrorsSidecarStartEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Helper binary didn't start'
	String get title => 'Helper binary didn\'t start';
}

// Path: errors.sidecar_rpc
class TranslationsErrorsSidecarRpcEn {
	TranslationsErrorsSidecarRpcEn.internal(this._root);

	final Translations _root; // ignore: unused_field

	// Translations

	/// en: 'Background operation failed'
	String get title => 'Background operation failed';
}

/// The flat map containing all translations for locale <en>.
/// Only for edge cases! For simple maps, use the map function of this library.
///
/// The Dart AOT compiler has issues with very large switch statements,
/// so the map is split into smaller functions (512 entries each).
extension on Translations {
	dynamic _flatMapFunction(String path) {
		return switch (path) {
			'welcome.title' => 'Welcome to Deckhand',
			'welcome.helper' => 'Flash, set up, and maintain Klipper-based printers. This wizard walks\nyou through replacing vendor firmware with Kalico or Klipper end-to-\nend, either in place on your existing OS or on a fresh install.\n',
			'welcome.action_start' => 'Start',
			'welcome.action_settings' => 'Settings',
			'welcome.card_first_time.title' => 'First time here?',
			'welcome.card_first_time.body' => 'The wizard will ask which printer you have, try to reach it over\nSSH using known default credentials, then let you pick what you\nwant to replace and what you want to keep.\n',
			'welcome.card_safety.title' => 'Safety',
			'welcome.card_safety.body' => 'Nothing destructive happens without explicit confirmation. Deckhand\ncan back up your entire eMMC to an image before any firmware swap,\nso you always have a route back to stock.\n',
			'pick_printer.title' => 'Which printer are you setting up?',
			'pick_printer.helper' => 'Deckhand supports these printers. Pick yours - we use that choice to\nload the right profile before anything else.\n',
			'pick_printer.show_stubs' => 'Show stub profiles',
			'pick_printer.no_printer_link' => 'My printer isn\'t here →',
			'pick_printer.action_continue' => 'Continue',
			'pick_printer.action_back' => 'Back',
			'pick_printer.registry_error' => ({required Object error}) => 'Failed to load printer registry: ${error}',
			'connect.title' => 'Connect to your printer',
			'connect.helper' => 'Deckhand scans your LAN two ways: mDNS for printers that advertise\nMoonraker, and a TCP sweep of port 7125 across your local subnet.\nEach host is probed to see whether it matches your selected\nprofile - confirmed matches surface at the top.\n',
			'connect.field_host' => 'Host or IP',
			'connect.hint_host' => 'e.g. 192.168.1.50 or mkspi.local',
			'connect.action_connect' => 'Connect',
			'connect.action_connecting' => 'Connecting…',
			'connect.action_rescan' => 'Rescan',
			'connect.host_key_title_new' => 'First time connecting to this printer',
			'connect.host_key_body_new' => 'Deckhand has not seen this printer before. Compare the fingerprint\nbelow against what the printer reports locally. If it matches,\naccept it and Deckhand will remember it for future connections.\n',
			'connect.host_key_confirm_new' => 'Accept and connect',
			'connect.host_key_title_mismatch' => 'This printer\'s SSH fingerprint changed',
			'connect.host_key_body_mismatch' => 'The fingerprint presented by this printer does not match the one\nDeckhand saved previously. This can happen if you reinstalled the\nprinter\'s OS, but it can also indicate something is intercepting\nthe connection. If you expected this change, clear the pinned\nfingerprint in Settings and try again.\n',
			'connect.section_discovered' => 'Found on your network',
			'connect.section_manual' => 'Or enter manually',
			'connect.empty_state' => 'Nothing responded on port 7125 across your local subnet, and no\nMoonraker mDNS advertisements were seen either. Your printer may be\non a different VLAN, behind a firewall, or using a non-default\nport - enter the IP/hostname below.\n',
			'connect.match_confirmed' => ({required Object profile}) => 'Looks like your ${profile}',
			'connect.match_probable' => ({required Object profile}) => 'Probably your ${profile}',
			'connect.match_miss' => ({required Object profile}) => 'Does not look like ${profile}',
			'connect.match_checking' => 'Checking...',
			'connect.reason_marker_with_id' => ({required Object profileId}) => 'installed by Deckhand as ${profileId}',
			'connect.reason_marker_generic' => 'Deckhand marker file present',
			'connect.reason_object' => ({required Object object}) => 'Klipper config uses `${object}`',
			'connect.reason_hostname' => ({required Object hostname}) => 'hostname `${hostname}` matches profile',
			'connect.semantics_confirmed' => ({required Object profile, required Object reason}) => 'confirmed match for ${profile}${reason}',
			'connect.semantics_probable' => ({required Object profile, required Object reason}) => 'probable match for ${profile}${reason}',
			'connect.semantics_miss' => ({required Object profile}) => 'does not match ${profile}',
			'connect.semantics_unknown' => 'match status unknown',
			'verify.title' => 'Verify your printer',
			'verify.helper' => 'We\'ll run a few quick checks against your connected printer to\nconfirm this profile matches. Warnings don\'t block the wizard - you\ncan always proceed.\n',
			'verify.action_continue' => 'Continue',
			'verify.action_back' => 'Back',
			'choose_path.title' => 'Which path do you want to take?',
			'choose_path.helper' => 'Choose whether to reuse the OS already on your printer or wipe the\neMMC and install a fresh Armbian image. Both lead to the same final\nstate (Kalico or Klipper + your chosen web UI); they differ in blast\nradius and in what you have to manage yourself.\n',
			'choose_path.stock.title' => 'Keep my current OS',
			'choose_path.stock.body' => 'Transforms your printer in place. Snapshots the stock Klipper\ninstall, then swaps in the firmware you pick. Any vendor services\nyou don\'t want are disabled or removed per your selections.\n',
			'choose_path.fresh.title' => 'Flash a new OS',
			'choose_path.fresh.body' => 'Wipes the eMMC and installs a clean Armbian image. Strongly\npreferred if you have an eMMC-to-USB adapter handy and want a\nfully known-good base.\n',
			'choose_path.action_continue' => 'Continue',
			'choose_path.action_back' => 'Back',
			'errors.dialog_title_generic' => 'Something went wrong',
			'errors.action_retry' => 'Retry',
			'errors.action_start_over' => 'Start over',
			'errors.action_save_debug_bundle' => 'Save debug bundle',
			'errors.ssh_connection.title' => 'Can\'t reach the printer',
			'errors.ssh_auth.title' => 'Couldn\'t sign in to the printer',
			'errors.host_key_mismatch.title' => 'Printer\'s SSH fingerprint changed',
			'errors.flash.title' => 'Disk flash failed',
			'errors.disk_enumeration.title' => 'Couldn\'t enumerate local disks',
			'errors.elevation_required.title' => 'Administrator permission required',
			'errors.profile_fetch.title' => 'Couldn\'t load printer profiles',
			'errors.profile_parse.title' => 'Malformed printer profile',
			'errors.upstream_fetch.title' => 'Couldn\'t fetch an upstream component',
			'errors.sidecar_start.title' => 'Helper binary didn\'t start',
			'errors.sidecar_rpc.title' => 'Background operation failed',
			'firmware.title' => 'Pick your firmware',
			'firmware.helper' => 'Kalico is a community-maintained Klipper fork with weekly rebases\nand helpful extras (gcode_shell_command, danger_options). Mainline\nKlipper is upstream/master - more conservative.\n',
			'webui.title' => 'Which web interface?',
			'webui.helper' => 'Web dashboards for controlling the printer from a browser. They\nboth talk to the same backend (Moonraker), so you can install\nboth and switch between them any time.\n',
			'webui.requirement_ok' => 'Pick at least one. This step cannot be skipped.',
			'webui.requirement_missing' => 'Pick at least one to continue.',
			'kiauh.title' => 'Install KIAUH?',
			'screen_choice.title' => 'Pick a screen daemon',
			'services.counter' => ({required Object current, required Object total}) => '${current} of ${total}',
			'files.title' => 'Leftover files',
			'hardening.title' => 'Security hardening (optional)',
			'flash_target.title' => 'Which disk should we flash?',
			'choose_os.title' => 'Which OS image?',
			'flash_confirm.title' => 'Confirm the wipe',
			'flash_progress.title_running' => 'Writing image',
			'flash_progress.title_done' => 'Flash complete',
			'first_boot.title' => 'Put the eMMC back in the printer',
			'first_boot_setup.title' => 'First boot setup',
			'review.title' => 'Review your choices',
			'progress.title_installing' => 'Installing...',
			'progress.title_done' => 'All done',
			'progress.title_failed' => 'Something went wrong',
			'progress.title_working' => 'Working...',
			'progress.phase_os_download' => 'Downloading image',
			'progress.phase_flash_disk' => 'Writing image',
			'progress.phase_wait_for_ssh' => 'Waiting for the printer to come back',
			'progress.phase_install_firmware' => 'Installing firmware',
			'progress.phase_install_stack' => 'Installing Moonraker + web UI',
			'progress.phase_link_extras' => 'Copying Klipper extras',
			'progress.phase_install_screen' => 'Installing the touchscreen UI',
			'progress.phase_flash_mcus' => 'Flashing MCU firmware',
			'progress.phase_apply_services' => 'Cleaning up stock services',
			'progress.phase_apply_files' => 'Cleaning up stock files',
			'progress.phase_snapshot_paths' => 'Backing up stock files',
			'progress.phase_write_file' => 'Writing config',
			'progress.phase_install_marker' => 'Marking this printer as Deckhand-managed',
			'progress.phase_verify' => 'Verifying',
			'progress.phase_script' => 'Running setup script',
			'progress.phase_ssh_commands' => 'Running remote commands',
			'progress.phase_conditional' => 'Evaluating condition',
			'progress.action_finish' => 'Finish',
			'progress.action_close' => 'Close',
			'progress.action_running' => 'Running...',
			'progress.prompt_default_title' => 'One moment',
			'progress.prompt_default_action' => 'Continue',
			'progress.choose_one_default_title' => 'Pick one',
			'progress.choose_one_ok' => 'OK',
			'progress.disk_picker_title' => 'Pick the target disk',
			'progress.disk_picker_cancel' => 'Cancel',
			'progress.disk_picker_confirm' => 'Use this disk',
			'progress.disk_picker_no_disks_title' => 'No removable disks found',
			'progress.disk_picker_no_disks_body' => 'Plug the printer eMMC into a USB adapter, then try again. Internal\ndisks are dimmed here to prevent accidents.\n',
			'progress.disk_picker_list_error_title' => 'Could not list disks',
			'progress.semantics_progress_label' => 'Current step progress',
			'progress.semantics_progress_indeterminate' => 'indeterminate',
			'progress.semantics_progress_percent' => ({required Object percent}) => '${percent} percent',
			'progress.semantics_log_label' => 'Step execution log',
			'done.title' => 'Setup complete',
			'done.next_steps' => 'Next steps',
			'settings.title' => 'Settings',
			'settings.section_profiles' => 'Printer profiles',
			'settings.profiles_local_dir_label' => 'Local profiles directory',
			'settings.profiles_local_dir_hint' => 'Point Deckhand at a checked-out copy of deckhand-builds on this\nmachine instead of fetching main from GitHub. Useful for profile\nauthoring. Leave empty to fetch from GitHub.\n',
			'settings.profiles_local_dir_active' => 'Using local dir',
			'settings.profiles_local_dir_github' => 'Fetching from GitHub',
			'settings.profiles_local_dir_pick' => 'Pick folder...',
			'settings.profiles_local_dir_clear' => 'Clear',
			'settings.profiles_local_dir_invalid' => 'Directory not found or unreadable.',
			'common.action_back' => 'Back',
			'common.action_continue' => 'Continue',
			'common.action_finish' => 'Finish',
			'common.action_cancel' => 'Cancel',
			_ => null,
		};
	}
}
