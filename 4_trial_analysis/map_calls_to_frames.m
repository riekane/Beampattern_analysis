function cf = map_calls_to_frames(bpp, frame_rate, n_frames, seg)
%MAP_CALLS_TO_FRAMES  Place each with-track call on the Vicon frame timeline.
%
%   cf = MAP_CALLS_TO_FRAMES(bpp, frame_rate, n_frames)
%   cf = MAP_CALLS_TO_FRAMES(bpp, frame_rate, n_frames, seg)
%
% Returns, for every call in bpp.mic_data.call_idx_w_track (i.e. row-for-row
% with proc.bat_loc_at_call and proc.beam_aim_az_el_deg), the Vicon frame it was
% emitted at and its time.
%
% WHY THIS FORMULA. Stage 1 (bp_proc_vicon) builds BOTH the audio time axis
% (mic_data.sig_t) and the track time axis with `-fliplr(0:N-1)/fs`, so both
% meet at t = 0 at their LAST sample/frame (END-aligned). run_beamaim_maze's
% header says the same: the Vicon<->Avisoft alignment lives in stage 1 and its
% time bases "meet at the END, via -fliplr". We reproduce exactly that mapping
% here rather than re-deriving a start-aligned frame (which would contradict
% stage 1). We deliberately do NOT use track.call_loc_idx_on_track_interp: in
% bp_proc that vector is filled BEFORE two later call-filtering steps, so it can
% be longer than / misaligned with call_idx_w_track.
%
% A call at audio sample `loc` has time  t = -(nsamp - loc)/audio_fs  (<= 0),
% and the frame with that same end-aligned time is
%       frame = n_frames + frame_rate * t.
%
% INPUT
%   bpp        loaded proc struct (needs mic_data.call, mic_data.fs,
%              mic_data.sig_t, mic_data.call_idx_w_track).
%   frame_rate Hz (bat_pos.frame_rate).
%   n_frames   number of Vicon frames in the trajectory (size(traj,1)).
%   seg        (optional) output of segment_flight; if given, speed_at_call and
%              time_before_takeoff are filled.
%
% OUTPUT (struct cf), all nC x 1 with nC = numel(call_idx_w_track):
%   .call_idx              raw index into mic_data.call
%   .loc                   audio sample index used
%   .t                     emission time, s (END-aligned; matches seg.t)
%   .frame                 fractional Vicon frame (clamped to [1 n_frames])
%   .speed_at_call         m/s at the call (NaN if seg not given)
%   .time_before_takeoff   s; positive => emitted BEFORE take-off (NaN if no seg
%                          or no take-off found)
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

md            = bpp.mic_data;
calls_w_track = md.call_idx_w_track(:);
nC            = numel(calls_w_track);
audio_fs      = double(md.fs);
nsamp         = numel(md.sig_t);

% prefer the detected call start; fall back to the peak location `locs`
loc = nan(nC,1);
for i = 1:nC
    c = md.call(calls_w_track(i));
    if isfield(c,'call_start_idx') && ~isempty(c.call_start_idx) && isfinite(c.call_start_idx)
        loc(i) = double(c.call_start_idx);
    else
        loc(i) = double(c.locs(1));
    end
end
loc = max(loc, 1);

t     = -(nsamp - loc)/audio_fs;                 % s, END-aligned (<= 0)
frame = n_frames + frame_rate .* t;              % fractional frame
frame = min(max(frame, 1), n_frames);

cf.call_idx = calls_w_track;
cf.loc      = loc;
cf.t        = t;
cf.frame    = frame;
cf.speed_at_call       = nan(nC,1);
cf.time_before_takeoff = nan(nC,1);

if nargin >= 4 && ~isempty(seg)
    fi = (1:numel(seg.speed))';
    cf.speed_at_call = interp1(fi, seg.speed, frame, 'linear', NaN);
    if isfield(seg,'takeoff_t') && ~isnan(seg.takeoff_t)
        cf.time_before_takeoff = seg.takeoff_t - t;   % >0 means before take-off
    end
end
end
