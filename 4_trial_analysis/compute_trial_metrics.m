function trow = compute_trial_metrics(keys, seg, cf, pc, outcome, frame_rate, n_frames)
%COMPUTE_TRIAL_METRICS  Assemble the one-row-per-trial summary (analysis 1a + 2).
%
%   trow = COMPUTE_TRIAL_METRICS(keys, seg, cf, pc, outcome, frame_rate, n_frames)
%
% Combines the pieces from the other stage-4 functions into a single table row
% for the trial-level master. Call rate (1a) is reported two ways:
%   * call_rate_hz          = all with-track calls / whole tracked duration
%   * preflight_call_rate_hz = pre-flight calls / time on the take-off perch
% because "calls per trial" is ambiguous and the two denominators answer
% different questions.
%
% INPUT
%   keys      struct with identifying fields: bat_id, session, trial, date
%             (any may be '' / NaN). Copied verbatim into the row as the join key.
%   seg       segment_flight output.
%   cf        map_calls_to_frames output.
%   pc        extract_preflight_calls table (pre-flight calls only).
%   outcome   classify_trial_outcome output.
%   frame_rate, n_frames  trajectory frame rate (Hz) and length.
%
% OUTPUT: single-row table `trow`.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

nC       = numel(cf.call_idx);
trial_dur_s = (n_frames-1)/frame_rate;
call_rate_hz = nC / trial_dur_s;

n_pf = height(pc);
if ~isnan(seg.perch_sit_dur_s) && seg.perch_sit_dur_s > 0
    preflight_call_rate_hz = n_pf / seg.perch_sit_dur_s;
else
    preflight_call_rate_hz = NaN;
end

% aggregate pre-flight beam aim (head-aim proxy)
if n_pf > 0
    mean_pf_az = mean(pc.beam_az_deg,'omitnan');
    mean_pf_el = mean(pc.beam_el_deg,'omitnan');
    mean_pf_az_goalrel = mean(pc.az_goal_rel_deg,'omitnan');
    % net left/right lean: fraction aimed left (+X) of the straight-to-target line
    frac_left = mean(pc.az_goal_rel_deg > 0, 'omitnan');
    mean_pf_speed = mean(pc.speed_at_call_mps,'omitnan');
else
    mean_pf_az=NaN; mean_pf_el=NaN; mean_pf_az_goalrel=NaN; frac_left=NaN; mean_pf_speed=NaN;
end

vals = { ...
    string(local_g(keys,'bat_id','')), string(local_g(keys,'session','')), ...
    string(local_g(keys,'trial','')),  string(local_g(keys,'date','')), ...
    frame_rate, n_frames, trial_dur_s, ...
    seg.takeoff_frame, seg.land_frame, seg.takeoff_t, seg.land_t, ...
    seg.perch_sit_dur_s, seg.flight_dur_s, seg.min_dist_lp_xy_mm, ...
    outcome.landed, outcome.end_dist_LP_mm, outcome.end_speed_mps, ...
    outcome.end_zone_id, string(outcome.end_zone_name), ...
    string(outcome.side_first), outcome.side_first_zone, outcome.side_first_frame, ...
    string(outcome.target_side), local_tri(outcome.side_first_correct), ...
    nC, n_pf, call_rate_hz, preflight_call_rate_hz, ...
    mean_pf_az, mean_pf_el, mean_pf_az_goalrel, frac_left, mean_pf_speed };
names = {'bat_id','session','trial','date', ...
      'frame_rate','n_frames','trial_dur_s', ...
      'takeoff_frame','land_frame','takeoff_t_s','land_t_s', ...
      'perch_sit_dur_s','flight_dur_s','min_dist_LP_xy_mm', ...
      'landed','end_dist_LP_mm','end_speed_mps','end_zone_id','end_zone_name', ...
      'side_first','side_first_zone','side_first_frame','target_side','side_first_correct', ...
      'n_calls_w_track','n_preflight_calls','call_rate_hz','preflight_call_rate_hz', ...
      'mean_preflight_az_deg','mean_preflight_el_deg','mean_preflight_az_goalrel_deg', ...
      'frac_preflight_aim_left','mean_preflight_speed_mps'};
% Coerce every value to a 1x1 (scalar / string scalar) and report any offender,
% so a stray non-scalar upstream field can't crash the table build.
for ii = 1:numel(vals)
    v = vals{ii};
    if ischar(v) || isstring(v)
        sv = string(v);
        if numel(sv) ~= 1
            warning('compute_trial_metrics:nonscalar', 'field "%s" is a non-scalar string (size %s)', names{ii}, mat2str(size(sv)));
            if isempty(sv), sv = ""; else, sv = sv(1); end
        end
        vals{ii} = sv;
    else
        if isempty(v)
            warning('compute_trial_metrics:empty', 'field "%s" is EMPTY -> NaN', names{ii});
            v = NaN;
        elseif ~isscalar(v)
            warning('compute_trial_metrics:nonscalar', 'field "%s" is non-scalar (size %s) -> using first element', names{ii}, mat2str(size(v)));
            v = v(1);
        end
        vals{ii} = v;
    end
end
trow = table(vals{:}, 'VariableNames', names);
end

function v = local_g(s,f,d)
    if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
    if isnumeric(v), v = num2str(v); end
end
function t = local_tri(x)
    % encode logical-or-NaN as -1/0/1 so it survives CSV round-trips
    if isnan(x), t = -1; elseif x, t = 1; else, t = 0; end
end
