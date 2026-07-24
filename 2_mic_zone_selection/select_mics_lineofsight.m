function [mic_nums, vis, qc] = select_mics_lineofsight(bat_xy, mics_xy, all_mic_nums, walls)
%SELECT_MICS_LINEOFSIGHT  Keep mics with a clear XY line-of-sight to the bat.
%
%   [mic_nums, vis, qc] = SELECT_MICS_LINEOFSIGHT(bat_xy, mics_xy, all_mic_nums, walls)
%
% Occluder-aware mic selection from GEOMETRY instead of static per-zone lists: a
% mic is dropped if the straight segment bat->mic crosses any maze wall segment
% (in XY). Handles every bat position uniformly -- inside the maze (walls occlude
% the far side), below the exits (open, most mics visible), etc.
%
% INPUT
%   bat_xy       - [x y] bat position, mm, Vicon global frame.
%   mics_xy      - N x 2 mic positions (mm), SAME order as all_mic_nums.
%   all_mic_nums - 1 x N mic NUMBERS present/usable this session.
%   walls        - cell array of K x 2 polylines, each a maze wall
%                  (e.g. {zones.wallR, zones.wallL}). Consecutive rows = segments.
%
% OUTPUT
%   mic_nums - visible mic NUMBERS (subset of all_mic_nums).
%   vis      - N x 1 logical visibility mask.
%   qc       - struct: .n_visible, .n_total.
%
% NOTE: XY-only (maze walls treated as blocking regardless of height, since the
% wall heights aren't in the layout). Reasonable for a bat flying between walls;
% revisit if mics mounted high enough to see over a wall are wrongly dropped.
%
% Vicon+Avisoft beam-pattern pipeline, 2026. Written by Rie Kaneko on
% 7/14/2026

    n = numel(all_mic_nums); vis = true(n,1);
    segs = {};
    for w = 1:numel(walls)
        W = walls{w};
        for k = 1:size(W,1)-1, segs{end+1} = [W(k,1:2); W(k+1,1:2)]; end %#ok<AGROW>
    end
    for i = 1:n
        for s = 1:numel(segs)
            if local_seg_intersect(bat_xy(1:2), mics_xy(i,1:2), segs{s}(1,:), segs{s}(2,:))
                vis(i) = false; break;
            end
        end
    end
    mic_nums = all_mic_nums(vis);
    qc = struct('n_visible', sum(vis), 'n_total', n);
end

function tf = local_seg_intersect(p1,p2,p3,p4)
% strict intersection of segments p1p2 and p3p4 (ignores collinear/endpoint touch)
    d1=local_orient(p3,p4,p1); d2=local_orient(p3,p4,p2);
    d3=local_orient(p1,p2,p3); d4=local_orient(p1,p2,p4);
    tf = ((d1>0&&d2<0)||(d1<0&&d2>0)) && ((d3>0&&d4<0)||(d3<0&&d4>0));
end
function c = local_orient(a,b,p)
    c = (b(1)-a(1))*(p(2)-a(2)) - (b(2)-a(2))*(p(1)-a(1));
end
