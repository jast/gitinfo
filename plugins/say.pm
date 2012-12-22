use POE;
{
	irc_commands => {
		say => sub {
			my ($source, $targets, $args, $auth) = @_;
			my ($chan, $text) = split(/\s+/, $args, 2);
			BotIrc::check_ctx(authed => 1, priv => 'say') or return;

			BotIrc::ctx_redirect_to_channel('wisdom', $chan) or do {
				BotIrc::send_noise("Channel '$chan' not found in config; denied.");
				return;
			};
			BotIrc::send_wisdom($text);
		}
	},
};
