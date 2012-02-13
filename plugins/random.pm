my @cache;
my @ids;
my $cache_items = sub {
	@cache = ();
	@ids = ();
	my $res = $BotDb::db->selectall_arrayref("SELECT rowid, random FROM random_stuff", {Slice => {}});
	for (@$res) {
		push @ids, $_->{rowid};
		push @cache, $_->{random};
	}
};
{
	schemata => {
		0 => [
			"CREATE TABLE random_stuff (random TEXT NOT NULL,
				added_by TEXT NOT NULL,
				added_at INT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
		],
	},
	on_load => sub {
		$cache_items->();
	},
	irc_commands => {
		random => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;

			if (!$args) {
				my $i = int(rand(@cache));
				BotIrc::send_wisdom($cache[$i] ." [". $ids[$i] ."]");
				return 1;
			}
			BotIrc::check_ctx(authed => 1) or return;
			my ($cmd, $data) = split(/\s+/, $args, 2);
			if ($cmd eq 'add') {
				$BotDb::db->do("INSERT INTO random_stuff (random, added_by) VALUES(?, ?)", {}, $data, $source);
				$cache_items->();
				BotIrc::send_noise("Okay.");
			} elsif ($cmd eq 'rehash') {
				$cache_items->();
				BotIrc::send_noise("Okay.");
			} elsif ($cmd eq 'delete') {
				BotIrc::check_ctx(priv => 'random_delete') or return;
				$BotDb::db->do("DELETE FROM random_stuff WHERE rowid=?", $data);
				$cache_items->();
				BotIrc::send_noise("Okay.");
			}
		}
	},
};
