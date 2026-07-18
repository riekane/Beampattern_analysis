function T = append_to_master_table(new_rows, csv_path, key_vars)
%APPEND_TO_MASTER_TABLE  Keyed upsert of rows into a CSV (+ .mat) master table.
%
%   T = APPEND_TO_MASTER_TABLE(new_rows, csv_path, key_vars)
%
% Reads the existing master (if any), removes any rows whose key matches a key
% in new_rows, appends new_rows, and writes back to csv_path AND the sibling
% <csv_path without .csv>.mat (variable `T`). This makes re-running a trial
% idempotent: its rows are replaced, not duplicated.
%
% INPUT
%   new_rows  table of rows to add (must contain the key_vars columns).
%   csv_path  destination .csv (created if absent; parent folder auto-created).
%   key_vars  cellstr of column names that jointly identify a unique record
%             (e.g. {'bat_id','session','trial'} for the trial master;
%              {'bat_id','session','trial','call_idx'} for the call master).
%
% OUTPUT: the full merged table T (also written to disk).
%
% Vicon+Avisoft beam-pattern pipeline, stage 4, 2026.

if isempty(new_rows), T = new_rows; return; end
[d,~,~] = fileparts(csv_path);
if ~isempty(d) && ~isfolder(d), mkdir(d); end

if isfile(csv_path)
    old = readtable(csv_path, 'TextType','string');
    old = local_align(old, new_rows);                 % union columns
    new2 = local_align(new_rows, old);
    keep = true(height(old),1);
    for i = 1:height(old)
        for j = 1:height(new2)
            if local_keymatch(old(i,:), new2(j,:), key_vars)
                keep(i) = false; break;
            end
        end
    end
    T = [old(keep,:); new2];
else
    T = new_rows;
end

writetable(T, csv_path);
matp = regexprep(csv_path,'\.csv$','.mat');
save(matp,'T');
fprintf('  wrote %d rows -> %s\n', height(T), csv_path);
end

function A = local_align(A, B)
    % add any columns B has that A lacks (filled with missing), keep A's order
    miss = setdiff(B.Properties.VariableNames, A.Properties.VariableNames, 'stable');
    for k = 1:numel(miss)
        col = B.(miss{k});
        if isnumeric(col),      A.(miss{k}) = nan(height(A),1);
        elseif isstring(col),   A.(miss{k}) = strings(height(A),1);
        elseif islogical(col),  A.(miss{k}) = false(height(A),1);
        else,                   A.(miss{k}) = repmat(missing,height(A),1);
        end
    end
end
function tf = local_keymatch(r1, r2, key_vars)
    tf = true;
    for k = 1:numel(key_vars)
        v = key_vars{k};
        a = r1.(v); b = r2.(v);
        if isstring(a)||ischar(a), eq = strcmp(string(a),string(b));
        else, eq = isequaln(a,b); end
        if ~eq, tf = false; return; end
    end
end
