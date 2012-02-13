use POE;
{
	ctl_commands => {
		voice => sub {
			my ($client, $data, @args) = @_;
			&BotCtl::require_control or return;
			if (!$BotIrc::irc->is_channel_member($BotIrc::config->{channel}, $args[0])) {
				$client->put("error:notinchan:That user couldn't be found in the channel.");
			} else {
				$BotIrc::irc->yield(mode => $BotIrc::config->{channel} => "+v" => $args[0]);
			}
		},
	},
	irc_commands => {
		voice => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return 1;
			my $nick = BotIrc::nickonly($source);

			$BotIrc::irc->yield(mode => $BotIrc::config->{channel} => "+v" => $source);
			return 1;
		},
	},
};


