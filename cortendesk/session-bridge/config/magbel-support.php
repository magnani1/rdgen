<?php

return ['token_groups' => json_decode((string) env('MAGBEL_SESSION_TOKEN_GROUPS', '{}'), true) ?: []];
