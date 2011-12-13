use JSON;
use POE;
{
	schemata => {
		0 => [
			"CREATE TABLE tt_triggers (trigger TEXT NOT NULL,
				lock INTEGER NOT NULL DEFAULT 0)",
			"CREATE TABLE tt_trigger_contents (tc_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
				trigger TEXT NOT NULL,
				exp TEXT NOT NULL,
				approved INT NOT NULL DEFAULT 1,
				changed_by TEXT NOT NULL,
				changed_at INT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
		],
	},
	on_load => sub {
		$BotIrc::heap->{ttr_cache} = {};
		my $res = $BotDb::db->selectall_arrayref("SELECT trigger, exp FROM tt_triggers NATURAL JOIN tt_trigger_contents WHERE approved=1", {Slice => {}});
		for (@$res) {
			$BotIrc::heap->{ttr_cache}{$_->{trigger}} = $_->{exp};
		}
	},
	before_unload => sub {
		delete $BotIrc::heap->{ttr_cache};
	},
	control_commands => {
		trigger_list => sub {
			my ($client, $data, @args) = @_;
			BotCtl::send($client, "ok", to_json($BotIrc::heap->{ttr_cache}, {utf8 => 1, canonical => 1}));
		},
	},
	irc_commands => {
		trigger_edit => sub {
			my ($source, $targets, $args, $auth) = @_;
			my $rpath = &BotIrc::return_path(@_) // return 0;
			return 1 if !BotIrc::public_command_authed($source, $auth);

			my ($trigger, $exp) = split(/\s+/, $args, 2);
			if (!$trigger || !$exp) {
				$BotIrc::irc->yield(privmsg => $rpath => "$source: syntax: .trigger_edit <name> <contents>");
				return 1;
			}
			if ($trigger =~ /[^a-z_-]/i) {
				$BotIrc::irc->yield(privmsg => $rpath => "$source: valid trigger names must consist of [a-zA-Z_-]");
				return 1;
			}
			return 1 if !BotIrc::public_check_antipriv($source, 'no_trigger_edit');
			my $res = $BotDb::db->selectrow_hashref("SELECT * FROM tt_triggers WHERE trigger=?", {}, $trigger);
			if (!defined $res) {
				if (defined $BotDb::db->err) {
					$BotIrc::irc->yield(privmsg => $rpath => "$source: uh-oh... something went wrong. Maybe this helps: $BotDb::db->errstr");
					BotIrc::error("text_trigger: fetching trigger info for $trigger: $BotDb::db->errstr");
					return 1;
				}
				# New trigger!
				return 1 if !BotIrc::public_check_priv($source, 'trigger_add', $auth);
				$BotDb::db->do("INSERT INTO tt_triggers (trigger) VALUES(?)", {}, $trigger);
			}
			return 1 if ($res->{lock} && !BotIrc::public_check_priv($source, 'trigger_edit_locked', $auth));

			if ($exp eq '-') {
				return 1 if (!BotIrc::public_check_priv($source, 'trigger_delete', $auth));
				$BotDb::db->do("DELETE FROM tt_trigger_contents WHERE trigger=?", {}, $trigger);
				$BotDb::db->do("DELETE FROM tt_triggers WHERE trigger=?", {}, $trigger);
				$BotIrc::heap->{ttr_cache}{$trigger} = undef;
			} else {
				$BotDb::db->do("INSERT INTO tt_trigger_contents (trigger, exp, changed_by) VALUES(?, ?, ?)", {}, $trigger, $exp, $source);
				$BotIrc::heap->{ttr_cache}{$trigger} = $exp;
			}
			$BotIrc::irc->yield(privmsg => $rpath => "$source: okay.");
		}
	},
	irc_on_anymsg => sub {
		my $rpath = &BotIrc::return_path(@_[ARG0, ARG1]) // return 0;
		return 0 if ($_[ARG2] !~ /(?:^|\s)!([a-z_-]+)(?:$|\s)/i);
		my $exp;

		$exp = $_[HEAP]->{ttr_cache}{$1};
		return 0 if !defined $exp;
		my $recp = "";
		if ($_[ARG2] =~ /^([a-z_\[\]\{\}\\\|][a-z0-9_\[\]\\\|`^{}-]+)[,:]\s+/) {
			$recp = "$1: ";
		}
		my $target = ($recp eq '' ? $rpath : $BotIrc::config->{channel});
		$BotIrc::irc->yield(privmsg => $target => "$recp$exp");
		return 1;
	},
};
