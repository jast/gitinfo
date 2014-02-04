use POE;
{
	irc_commands => {
		join => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx(priv => 'join') or return;

			chomp $args;
			my ($channel) = split(/\s+/, $args);
			if (!$channel) {
				# Auto-join
				my $chans = $BotIrc::irc->channels();
				my @new_chans = ();
				for (keys %{$BotIrc::config->{channel}}) {
					next if (exists $chans->{uc $_});
					$BotIrc::irc->yield(join => $_);
					push @new_chans, $_;
				}
				BotIrc::send_noise("Auto-joined configured channels: ". join(", ", @new_chans));
				return;
			}
			if ($channel !~ /^#\S+$/) {
				BotIrc::send_noise("I'm not particularly strict about channel names but you definitely didn't pass me a valid one there.");
				return;
			}
			if (!exists $BotIrc::config->{channel}{lc $channel}) {
				BotIrc::send_noise("You may not join me to channels that aren't configured. Sorry.");
				return;
			}
			if ($BotIrc::irc->is_channel_member($channel, $BotIrc::irc->nick_name())) {
				BotIrc::send_noise("Good morning, sleepyhead! I'm already on that channel.");
				return;
			}
			$BotIrc::irc->yield(join => $channel);
			BotIrc::send_noise("Okay.");
		},
	},
};


