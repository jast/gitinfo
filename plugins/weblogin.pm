use Digest::SHA1 qw(sha1_hex);
{
	on_load => sub {
		my $heap = $BotIrc::heap;
		$heap->{websessions} = {};
		$heap->{websessions_cleanup} = sub {
			for (keys %{$heap->{websessions}}) {
				next if time() - $heap->{websessions}{$_}{last_used} < $BotIrc::config->{http_sessionpurge}
			}
		};
	},
	before_unload => sub {
		delete $BotIrc::heap->{websessions};
	},
	control_commands => {
		login => sub {
			my ($client, $data, @args) = @_;
			my $heap = $BotIrc::heap->{websessions};
			if (!exists $heap->{$args[0]}) {
				BotCtl::send($client, "invalid");
				return;
			}
			my $session = $heap->{$args[0]};
			if (time() - $session->{last_used} > $BotIrc::config->{http_sessionexpire}) {
				BotCtl::send($client, "expired");
				delete $heap->{$args[0]};
				return;
			}
			BotCtl::set_level($data, $session->{username});
			$data->{session_id} = $args[0];
			$session->{last_used} = time();
			BotCtl::send($client, "ok", $session->{username});
		},
		logout => sub {
			if (!exists $data->{session_id}) {
				BotCtl::send($client, "invalid");
				return;
			}
			delete $heap->{$data->{session_id}};
			delete $data->{session_id};
			BotCtl::set_level($data, "!guest");
			BotCtl::send($client, "ok");
		},
	},
	irc_commands => {
		weblogin => sub {
			my ($source, $targets, $args, $auth) = @_;
			return 1 if !BotIrc::public_command_authed($source, $auth);

			# evil!
			my $auth = sha1_hex("$source:$$:".int(rand(1_000_000)).":".time());
			$BotIrc::heap->{websessions}{$auth} = {
				username	=> lc($source),
				last_used	=> time()
			};
			$BotIrc::irc->yield(notice => $source => "$source: please go to $BotIrc::config->{http_loginurl}$auth to log in (session cookies must be allowed).");
			return 1;
		},
	},
};
