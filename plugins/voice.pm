use POE;
{
	control_commands => {
		voice => sub {
			my ($client, $data, @args) = @_;
			if (!$BotIrc::irc->is_channel_member($BotIrc::config->{voice_channel}, $args[0])) {
				$client->put("error:notinchan:That user couldn't be found in the channel.");
			} else {
				$BotIrc::irc->yield(mode => $BotIrc::config->{voice_channel} => "+v" => $args[0]);
				$client->put($client, "ok");
			}
		},
	},
	irc_commands => {
		voice => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return 1;
			my $nick = BotIrc::nickonly($source);

			if (!$BotIrc::irc->is_channel_member($BotIrc::config->{voice_channel}, $nick)) {
				BotIrc::send_noise("What? You're not even in $BotIrc::config->{voice_channel}!");
				return 1;
			}
			$BotIrc::irc->yield(mode => $BotIrc::config->{voice_channel} => "+v" => $source);
			return 1;
		},
	},
};


