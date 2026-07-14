function bd = estimate_beam_direction(mic_xyz, bat_xyz, call_dB, opts)
%ESTIMATE_BEAM_DIRECTION  Marker-free head-aim proxy from a single call's beam pattern.
%
%   bd = ESTIMATE_BEAM_DIRECTION(mic_xyz, bat_xyz, call_dB)
%   bd = ESTIMATE_BEAM_DIRECTION(mic_xyz, bat_xyz, call_dB, opts)
%
% Port of the beam-direction logic inside beam_aim.m
% (Beampattern_analysis_Magdielexample), refactored into a standalone per-call
% function and made MARKER-FREE. The Magdiel pipeline measures head aim from
% three head markers (track.tip_smooth/left_smooth/right_smooth -> head_aim).
% Rie's rig has no head marker, so head direction is ESTIMATED from the sonar
% beam itself: the direction of maximum emitted energy is used as a proxy for
% where the bat's head points.
%
% METHOD  ------------------------------------------------------------------
%   1. Each mic's azimuth/elevation RELATIVE TO THE BAT in the room (Vicon
%      global) frame:  vec = mic_xyz - bat_xyz ; [az,el] = cart2sph(vec).
%      No head-centred frame is needed, so no head marker is required.
%   2. The loudest mic gives a coarse, discrete beam direction (peak-mic).
%   3. RBF-interpolate the per-mic dB over the (az,el) sphere and mask to the
%      convex region actually sampled by the mics.
%   4. ANCHORED refinement: search the masked interpolated surface only within
%      opts.anchor_win_deg of the peak mic, and take that local maximum as the
%      beam direction. This turns the coarse peak-mic into a CONTINUOUS estimate
%      (sub-mic resolution) while preventing the interpolation from jumping to a
%      spurious secondary lobe far from any strong mic (which the literal el~=0
%      midline slice of beam_aim.m does on automated, marker-free data).
%   5. A Gaussian fit of the azimuth slice through the beam elevation gives the
%      beam half-width `sigma`.
%
% WHY ANCHORED (not beam_aim.m's literal el~=0 midline): beam_aim.m reads the
% azimuth off the horizon slice el~=0 and is checked call-by-call in a GUI. Run
% unattended and marker-free, that slice is fragile: when the mics don't
% straddle the bat's horizon the RBF extrapolates at the sampled-region edge and
% returns azimuths tens-to-hundreds of degrees away from the true peak. Anchoring
% to the strongest mic keeps the automated estimate physically sensible. Set
% opts.method='midline' to reproduce beam_aim.m exactly if you want the GUI
% behaviour.
%
% FALLBACK: interpolation needs several mics spanning the beam. After maze
% occlusion a call may have too few in-view mics, so if nMics < opts.min_mics_fit
% (or the fit is unusable) the peak-mic direction is used and method='peak'. The
% peak-mic direction is ALWAYS returned (bd.peak_az_deg/peak_el_deg) so every
% call can be audited and the two methods compared.
%
% INPUT
%   mic_xyz  - (M x 3) positions of the CANDIDATE mics (already maze-selected &
%              good), same frame/units as bat_xyz (metres, Vicon global).
%   bat_xyz  - (1 x 3) bat position at this call (e.g. proc.bat_loc_at_call row).
%   call_dB  - (M x 1) received level (dB) at the desired frequency per mic.
%              NaN/Inf entries are ignored.
%   opts     - (optional) struct:
%                .method          'anchored' (default) | 'midline' | 'peak2d'
%                .interp_method   'rb_rbf' (default) | 'rb_natural'
%                .min_mics_fit    min mics to attempt interpolation (default 5)
%                .anchor_win_deg  half-window around peak mic, deg (default 40)
%                .midline_halfwidth_deg  half-width of el~=0 slice, deg (default 1)
%                .grid_step_deg   interpolation grid step, deg (default 1)
%
% OUTPUT (struct bd)
%   .az_deg        beam-aim azimuth   (deg, room frame)  <- head-aim proxy
%   .el_deg        beam-aim elevation (deg, room frame)
%   .sigma_deg     Gaussian beam half-width in azimuth (deg); NaN if peak method
%   .method        'anchored' | 'midline' | 'peak2d' | 'peak' | 'none'
%   .n_mics_used   number of mics that entered the estimate
%   .peak_az_deg   azimuth of loudest mic (always computed; audit/fallback)
%   .peak_el_deg   elevation of loudest mic
%
% Written for the Vicon+Avisoft beam-pattern pipeline, 2026. Depends on
% rbfcreate.m, rbfinterp.m and gaussfit.m (copied into this folder from the
% Magdiel beampattern_preprocessing toolbox).

if nargin < 4 || isempty(opts), opts = struct(); end
if ~isfield(opts,'method'),          opts.method          = 'anchored'; end
if ~isfield(opts,'interp_method'),   opts.interp_method   = 'rb_rbf';   end
if ~isfield(opts,'min_mics_fit'),    opts.min_mics_fit    = 5;          end
if ~isfield(opts,'anchor_win_deg'),  opts.anchor_win_deg  = 40;         end
if ~isfield(opts,'midline_halfwidth_deg'), opts.midline_halfwidth_deg = 1; end
if ~isfield(opts,'grid_step_deg'),   opts.grid_step_deg   = 1;          end

bd = struct('az_deg',NaN,'el_deg',NaN,'sigma_deg',NaN,'method','none', ...
            'n_mics_used',0,'peak_az_deg',NaN,'peak_el_deg',NaN);

% ---- keep only usable mics ----
call_dB = call_dB(:);
valid = isfinite(call_dB) & all(isfinite(mic_xyz),2);
if ~any(valid), return; end
mic_xyz = mic_xyz(valid,:);
dB      = call_dB(valid);
M       = numel(dB);
bd.n_mics_used = M;

% ---- mic az/el relative to bat in the ROOM frame (no head marker needed) ----
vec = mic_xyz - repmat(bat_xyz(:)', M, 1);
[az, el] = cart2sph(vec(:,1), vec(:,2), vec(:,3));

% ---- peak-mic direction (always available) ----
[~, ip] = max(dB);
paz = az(ip); pel = el(ip);
bd.peak_az_deg = rad2deg(paz);
bd.peak_el_deg = rad2deg(pel);

% ---- re-center azimuth onto a contiguous branch (fixes +/-180 wrap) ----
% cart2sph returns az in (-pi,pi]. If the in-view mics straddle the +/-180
% seam (bat pointing roughly toward -x with mics either side), a linear
% grid / convex mask / peak search would treat neighbouring mics as ~360
% deg apart and corrupt the interpolated surface. Work in az0-centred
% coordinates (circular mean at 0) so the samples are contiguous, then map
% the result back at the end.
az0  = atan2(mean(sin(az)), mean(cos(az)));   % circular mean of mic azimuths
azc  = wrap(az  - az0);                        % recentred sample azimuths
pazc = wrap(paz - az0);                        % recentred peak-mic azimuth

% ---- too few mics -> peak-mic ----
if M < opts.min_mics_fit
    bd.az_deg = bd.peak_az_deg; bd.el_deg = bd.peak_el_deg; bd.method = 'peak';
    return;
end

% ---- interpolate the beam pattern over (az,el) ----
step = opts.grid_step_deg*pi/180;
% grid is built in recentred azimuth (azc), so it is always contiguous
[azq, elq] = meshgrid(min(azc):step:max(azc), min(el):step:max(el));
try
    switch opts.interp_method
        case 'rb_natural'
            vq = griddata(azc, el, dB, azq, elq, 'natural');
        otherwise % 'rb_rbf'
            vq = rbfinterp([azq(:)'; elq(:)'], ...
                 rbfcreate([azc(:)'; el(:)'], dB(:)', 'RBFFunction','multiquadrics'));
            vq = reshape(vq, size(azq));
    end
catch
    bd.az_deg = bd.peak_az_deg; bd.el_deg = bd.peak_el_deg; bd.method = 'peak';
    return;
end

% mask to the convex region actually sampled by the mics
vq_norm = vq - max(dB);                     % dB relative to max (<= 0)
k = boundary(azc, el, 0);
if numel(k) >= 3
    inpoly = inpolygon(azq, elq, azc(k), el(k));
    vq_norm(~inpoly) = NaN;
end
if all(isnan(vq_norm(:)))
    bd.az_deg = bd.peak_az_deg; bd.el_deg = bd.peak_el_deg; bd.method = 'peak';
    return;
end

win = opts.anchor_win_deg*pi/180;

switch lower(opts.method)
    case 'midline'
        % --- literal beam_aim.m: azimuth off the el~=0 horizon slice ---
        hw = opts.midline_halfwidth_deg*pi/180;
        band = abs(elq) <= hw & ~isnan(vq_norm);
        if nnz(band) < 3   % horizon not sampled: use 2-D peak row
            [~,II] = max(vq_norm(:)); [Ir,~] = ind2sub(size(vq_norm),II);
            band = false(size(vq_norm)); band(Ir,:) = ~isnan(vq_norm(Ir,:));
        end
        [beam_az, beam_el, bd.sigma_deg] = fit_slice(azq, elq, vq_norm, band);
        bd.method = 'midline';

    case 'peak2d'
        % --- unconstrained 2-D interpolated peak ---
        [~,II] = max(vq_norm(:)); [Ir,Jc] = ind2sub(size(vq_norm),II);
        beam_az = azq(Ir,Jc); beam_el = elq(Ir,Jc);
        band = false(size(vq_norm)); band(Ir,:) = ~isnan(vq_norm(Ir,:));
        [~,~,bd.sigma_deg] = fit_slice(azq, elq, vq_norm, band);
        bd.method = 'peak2d';

    otherwise
        % --- ANCHORED (default): local max within win of the peak mic ---
        near = abs(wrap(azq - pazc)) <= win & abs(elq - pel) <= win & ~isnan(vq_norm);
        if nnz(near) < 3
            bd.az_deg = bd.peak_az_deg; bd.el_deg = bd.peak_el_deg; bd.method = 'peak';
            return;
        end
        vqm = vq_norm; vqm(~near) = NaN;
        [~,II] = max(vqm(:)); [Ir,Jc] = ind2sub(size(vqm),II);
        beam_az = azq(Ir,Jc); beam_el = elq(Ir,Jc);
        % sigma from the azimuth slice through the beam elevation, within win
        band = false(size(vq_norm));
        band(Ir,:) = ~isnan(vq_norm(Ir,:)) & abs(wrap(azq(Ir,:) - beam_az)) <= win;
        [~,~,bd.sigma_deg] = fit_slice(azq, elq, vq_norm, band);
        bd.method = 'anchored';
end

% beam_az/beam_el are in the recentred (azc) frame -> map azimuth back
bd.az_deg = rad2deg(wrap(beam_az + az0));
bd.el_deg = rad2deg(beam_el);
end

% ------------------------------------------------------------------------
function [beam_az, beam_el, sigma_deg] = fit_slice(azq, elq, vq_norm, band)
% Beam azimuth = argmax of the slice; sigma from a Gaussian fit of it.
    beam_az = NaN; beam_el = NaN; sigma_deg = NaN;
    if nnz(band) < 3, return; end
    a = azq(band); e = elq(band); v = vq_norm(band);
    v = v - min(v);                       % lift to >= 0
    [~, im] = max(v);
    beam_az = a(im); beam_el = e(im);
    try
        [sigma, ~] = gaussfit(a(:), v(:));
        sigma_deg = rad2deg(abs(sigma));
        if ~isfinite(sigma_deg) || sigma_deg <= 0 || sigma_deg > 120
            sigma_deg = NaN;   % implausible / non-converged fit
        end
    catch
        sigma_deg = NaN;
    end
end

function y = wrap(x)
% wrap angle differences to (-pi, pi]
    y = mod(x + pi, 2*pi) - pi;
end
