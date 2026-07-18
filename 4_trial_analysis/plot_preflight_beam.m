function figs = plot_preflight_beam(pc, outcome, seg, opts)
%PLOT_PREFLIGHT_BEAM  Visualise pre-flight sonar beam aim (analysis 1b).
%
%   figs = PLOT_PREFLIGHT_BEAM(pc, outcome, seg)
%   figs = PLOT_PREFLIGHT_BEAM(pc, outcome, seg, opts)
%
% Four views of the pre-flight beam-aim ("acoustic gaze", head-aim proxy) of a
% bat sitting on the take-off perch. Give it the preflight_calls table for ONE
% trial (from extract_preflight_calls) or the whole pooled master table; when
% pooling across trials use the GOAL-RELATIVE azimuth (az_goal_rel_deg), never
% raw room azimuth, because the perch moves between trials.
%
%   (1) az-el 2-D density heatmap            <- the "just map it" default
%   (2) landing-plane projection             <- where the beam "spotlight" lands
%       (beam ray from the bat extended to the landing-perch Y-plane)
%   (3) polar rose of goal-relative azimuth  <- left/right lean at a glance
%   (4) azimuth vs time-before-take-off      <- scanning dynamics
%
% If pc has a 'side_first' or 'landed' column (pooled master), panels are
% coloured by that outcome so you can see whether pre-flight aim predicts choice.
%
% INPUT
%   pc       preflight_calls table (needs beam_az_deg, beam_el_deg,
%            az_goal_rel_deg, time_before_takeoff_s; optional batx/y/z_mm).
%   outcome  classify_trial_outcome output for a single trial (for the landing-
%            plane geometry / target marker). May be [] when pooling.
%   seg      segment_flight output for a single trial (perch + LP centre). May
%            be [] when pooling (panel 2 is then skipped).
%   opts     .save_dir (''), .tag (''), .az_bins (36), .el_bins (18), .visible ('on')
%
% OUTPUT: figs, struct of figure handles.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if nargin < 4 || isempty(opts), opts = struct(); end
save_dir = local_getdef(opts,'save_dir','');
tag      = local_getdef(opts,'tag','preflight');
naz      = local_getdef(opts,'az_bins',36);
nel      = local_getdef(opts,'el_bins',18);
vis      = local_getdef(opts,'visible','on');
figs = struct();
if isempty(pc) || height(pc)==0, warning('plot_preflight_beam:empty','No pre-flight calls.'); return; end

az = pc.beam_az_deg; el = pc.beam_el_deg;
azg = pc.az_goal_rel_deg; tbt = pc.time_before_takeoff_s;
grp = local_group(pc);                                  % outcome grouping if present

% ---- (1) az-el density heatmap ----
figs.heatmap = figure('Visible',vis,'Name',[tag ' az-el heatmap']);
azedge = linspace(-180,180,naz+1); eledge = linspace(-90,90,nel+1);
Hc = histcounts2(az, el, azedge, eledge);
imagesc(azedge, eledge, Hc'); axis xy; colorbar;
xlabel('beam azimuth (deg, room frame)'); ylabel('beam elevation (deg)');
title(sprintf('%s: pre-flight beam-aim density (n=%d calls)', tag, height(pc)), 'Interpreter','none');

% ---- (2) landing-plane projection ----
if ~isempty(seg) && all(isfield(pc,{'batx_mm','baty_mm','batz_mm'}))
    figs.plane = figure('Visible',vis,'Name',[tag ' landing-plane projection']);
    y_plane = seg.lp_xyz(1,2);
    hold on;
    hit = nan(height(pc),2);
    for i = 1:height(pc)
        b = [pc.batx_mm(i) pc.baty_mm(i) pc.batz_mm(i)];
        d = local_sph2cart_dir(az(i), el(i));                 % unit dir, room frame
        if abs(d(2)) < 1e-6, continue; end
        s = (y_plane - b(2)) / d(2);                          % param to reach Y-plane
        if s <= 0, continue; end                              % beam points away
        p = b + s*d; hit(i,:) = [p(1) p(3)];                  % X (lateral), Z (height)
    end
    local_scatter(hit(:,1), hit(:,2), grp);
    plot(seg.lp_xyz(1,1), seg.lp_xyz(1,3), 'kp','MarkerSize',16,'MarkerFaceColor','y');
    xlabel('X on landing plane (mm)  [+X = LEFT/purple arm]');
    ylabel('Z height (mm)'); title([tag ': beam spotlight on the landing plane'],'Interpreter','none');
    grid on; axis equal; hold off;
end

% ---- (3) polar rose of goal-relative azimuth ----
figs.rose = figure('Visible',vis,'Name',[tag ' goal-relative azimuth']);
try
    polarhistogram(deg2rad(azg), 24);
catch
    rose(deg2rad(azg(~isnan(azg))), 24);
end
title(sprintf('%s: pre-flight aim vs straight-to-target (>0 = LEFT/+X)', tag),'Interpreter','none');

% ---- (4) scanning dynamics ----
figs.scan = figure('Visible',vis,'Name',[tag ' scanning trace']);
local_scatter(tbt, az, grp);
set(gca,'XDir','reverse');   % time-before-takeoff decreases toward take-off
xlabel('time before take-off (s)'); ylabel('beam azimuth (deg)');
title([tag ': pre-flight azimuth scanning'],'Interpreter','none'); grid on;

% ---- save ----
if ~isempty(save_dir)
    if ~isfolder(save_dir), mkdir(save_dir); end
    fn = fieldnames(figs);
    for i=1:numel(fn)
        saveas(figs.(fn{i}), fullfile(save_dir, sprintf('%s_%s.png', tag, fn{i})));
    end
    fprintf('  saved %d pre-flight figures -> %s\n', numel(fn), save_dir);
end
end

% ================= local helpers =================
function v = local_getdef(s,f,d)
    if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
function g = local_group(pc)
    g = [];
    if any(strcmp('side_first', pc.Properties.VariableNames)), g = string(pc.side_first);
    elseif any(strcmp('landed', pc.Properties.VariableNames)), g = string(pc.landed);
    end
end
function d = local_sph2cart_dir(az_deg, el_deg)
    a = deg2rad(az_deg); e = deg2rad(el_deg);
    d = [cos(e)*cos(a), cos(e)*sin(a), sin(e)];
end
function local_scatter(x, y, grp)
    if isempty(grp)
        scatter(x, y, 18, 'filled', 'MarkerFaceAlpha',0.6);
    else
        u = unique(grp); hold on;
        for k=1:numel(u)
            m = grp==u(k);
            scatter(x(m), y(m), 18, 'filled', 'DisplayName', char(u(k)), 'MarkerFaceAlpha',0.6);
        end
        legend('show','Location','best'); hold off;
    end
end
