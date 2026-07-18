function selftest_stage4()
%SELFTEST_STAGE4  Synthetic check of stage-4 segmentation + outcome under the
%real rig: UNTRACKED perch-sit and touchdown, TWO landing perches, landing judged
%by XY(+/-25 cm) + speed profile (NO Z gate; the perch top sits below the tracked
%flight and the descent is untracked). Prints PASS/FAIL. No real data/acoustics.
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

fprintf('== selftest_stage4 ==\n');
maze.start_line = [-500 1000 0; 500 1000 0];
maze.left_wall  = [-500 1000 0; -300 -500 0; -800 -2800 0];
maze.right_wall = [ 500 1000 0;  300 -500 0;  800 -2800 0];
frame_rate = 250;
tp  = [0 1560 261];
LP  = [850 -3000 462; -850 -3000 462];    % landing perch 1 = LEFT (+X), 2 = RIGHT (-X)

F = 1000; traj = nan(F,3);
fly = 401:820; land = 821:950;            % 1-400 & 951-1000 UNTRACKED
fs = [0 1560 1100]; fe = [850 -3000 1100];
for k = 1:numel(fly), a = k/numel(fly); traj(fly(k),:) = (1-a)*fs + a*fe; end
traj(land,:) = repmat([850 -3000 1100],numel(land),1) + 0.3*randn(numel(land),3);  % settles at LEFT perch XY
opts = struct('tp_xyz',tp,'lp_xyz',LP);
seg = segment_flight(traj, frame_rate, maze, opts);
out = classify_trial_outcome(traj, frame_rate, maze, seg);

% NEG 1: fly over the perch XY but never slow
traj2 = nan(F,3); af = 401:950;
for k=1:numel(af), a=k/numel(af); traj2(af(k),:) = (1-a)*fs + a*[850 -3000 1100]; end
o2 = classify_trial_outcome(traj2, frame_rate, maze, segment_flight(traj2,frame_rate,maze,opts));
% NEG 2: stop, but far from both perches
traj3 = nan(F,3);
for k=1:numel(fly), a=k/numel(fly); traj3(fly(k),:) = (1-a)*fs + a*[0 -1500 1100]; end
traj3(land,:) = repmat([0 -1500 1100],numel(land),1)+0.3*randn(numel(land),3);
o3 = classify_trial_outcome(traj3, frame_rate, maze, segment_flight(traj3,frame_rate,maze,opts));

n=0;
n=chk(n, ~isnan(seg.takeoff_frame), 'take-off found');
n=chk(n, ~isnan(seg.land_frame), 'landing found (XY+speed)');
n=chk(n, out.landed==true, 'landed==true');
n=chk(n, out.landed_perch_id==1, sprintf('landed on perch 1=LEFT (got %g)',out.landed_perch_id));
n=chk(n, strcmp(out.side_first,'left'), sprintf('side_first left (got "%s")',out.side_first));
n=chk(n, o2.landed==false, sprintf('fast fly-over NOT landed (got %d)',o2.landed));
n=chk(n, o3.landed==false, sprintf('stop far from perches NOT landed (got %d)',o3.landed));

fprintf('== %d/7 checks passed ==\n', n);
if n==7, fprintf('SELFTEST PASSED\n'); else, warning('SELFTEST had failures'); end
end
function n = chk(n, cond, msg)
    if cond, n=n+1; fprintf('  PASS  %s\n', msg); else, fprintf('  FAIL  %s\n', msg); end
end
