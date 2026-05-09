% qpsk_uart_capture_demod.m
% 读取 uart_capture_qpsk.py 导出的原始 ADC 样本，做一个面向当前 bring-up
% 阶段的最小 QPSK 离线解调。
%
% 当前脚本假设：
% 1) 板端顶层仍使用 pl_comm_top_fixed_cfg
% 2) QPSK 测试源模式为 Gray 循环 00 -> 01 -> 11 -> 10
% 3) clk_io = clk_adc = clk_dac = 100 MHz
% 4) TX 侧 QPSK NCO 相位增量仍为 24'h11EB85（约 7 MHz）

clear; clc;

%% ===== 可调参数 =====
ADC_DW          = 10;
CLK_SAMPLE_HZ   = 100e6;
PHASE_W         = 24;
PHASE_INC       = hex2dec('11EB85');
SPS             = 50;
RRC_BETA        = 0.50;
RRC_SPAN_SYMS   = 8;
SKIP_SAMPLES    = 300;
SKIP_SCORE_SYMS = 50;
EXPORT_DECISIONS = true;
ALLOW_NONZERO_UPPER_BITS = false;

% 如果你想手工指定某一次采集，可把 json_file 改成具体路径；
% 留空时自动选取 Tool/data 下最新的 uart_capture_*.json
json_file = '';

%% ===== 定位并读取采集文件 =====
if isempty(json_file)
    json_file = find_latest_capture_json();
end
fprintf('Using capture metadata: %s\n', json_file);

meta = jsondecode(fileread(json_file));
[capture_prefix, raw_u16] = load_capture_samples(json_file, meta);

fprintf('Loaded %d raw samples from capture.\n', numel(raw_u16));
fprintf('Capture metadata: sample_count=%d, payload_bytes=%d\n', ...
    meta.sample_count, meta.payload_bytes);

%% ===== ADC 码型整理 =====
adc_mask = uint16(2^ADC_DW - 1);
upper_mask = bitcmp(adc_mask);
upper_bit_idx = find(bitand(uint16(raw_u16), upper_mask) ~= 0);
adc_raw = bitand(uint16(raw_u16), adc_mask);

if ~isempty(upper_bit_idx)
    msg = sprintf(['Detected %d sample(s) with non-zero upper bits above ADC_DW=%d. ' ...
                   'First bad index = %d. This usually means the capture was exported ' ...
                   'with a non packet-aligned DMA build or the sample container is invalid.'], ...
                  numel(upper_bit_idx), ADC_DW, upper_bit_idx(1) - 1);
    if ALLOW_NONZERO_UPPER_BITS
        warning('%s Falling back to low %d bits only.', msg, ADC_DW);
    else
        error('%s Rebuild the board software with packet-aligned DMA capture and recapture data.', msg);
    end
end

if numel(adc_raw) <= SKIP_SAMPLES + SPS
    error('样本数不足：numel(adc_raw)=%d, SKIP_SAMPLES=%d, SPS=%d', ...
        numel(adc_raw), SKIP_SAMPLES, SPS);
end

adc_u = double(adc_raw(:));
adc_mid = 2^(ADC_DW - 1);
adc_signed = adc_u - adc_mid;
adc_signed = adc_signed - mean(adc_signed(SKIP_SAMPLES+1:end));

fprintf('ADC mean(after centering) = %.3f\n', mean(adc_signed));
fprintf('ADC rms  (after centering) = %.3f\n', sqrt(mean(adc_signed .^ 2)));

%% ===== 数字下变频 =====
x = adc_signed(SKIP_SAMPLES+1:end);
n = (0:numel(x)-1).';
carrier_cyc_per_samp = double(PHASE_INC) / 2^PHASE_W;
carrier_hz = carrier_cyc_per_samp * CLK_SAMPLE_HZ;
lo = exp(-1j * 2 * pi * carrier_cyc_per_samp * n);
bb = x .* lo;
bb = bb - mean(bb);
h_rrc = rrc_impulse_rrc(RRC_BETA, SPS, RRC_SPAN_SYMS);
bb_filt = conv(bb, h_rrc, 'same');

fprintf('Carrier estimate from PHASE_INC: %.6f MHz\n', carrier_hz / 1e6);

%% ===== 定时搜索 + 匹配滤波后相位/频偏校正 + Gray 序列对齐 =====
result = search_best_demod(bb_filt, SPS, SKIP_SCORE_SYMS, CLK_SAMPLE_HZ);

fprintf('\n=== Demod Summary ===\n');
fprintf('Timing offset     : %d sample(s)\n', result.timing_offset);
fprintf('Usable symbols    : %d\n', result.num_symbols);
fprintf('Gray seq shift    : %d\n', result.gray_shift);
fprintf('Gray match ratio  : %.4f\n', result.match_ratio);
fprintf('Phase offset      : %.3f deg\n', result.phase_offset_deg);
fprintf('Phase slope       : %.4f deg/sym\n', result.phase_slope_deg_per_sym);
fprintf('Residual CFO      : %.3f kHz\n', result.cfo_hz / 1e3);
fprintf('Symbol RMS        : %.3f\n', result.symbol_rms);

fprintf('First 16 decided symbols [bitI bitQ | dec]:\n');
disp([result.bits(1:min(16,end), :) result.codes(1:min(16,end))]);

%% ===== 导出判决结果 =====
if EXPORT_DECISIONS
    export_demod_csv(capture_prefix, result);
end

%% ===== 可视化 =====
plot_demod_views(adc_signed, x, bb_filt, result, CLK_SAMPLE_HZ, carrier_hz, SPS);


function json_file = find_latest_capture_json()
    data_dir = fullfile('..', 'data');
    entries = dir(fullfile(data_dir, 'uart_capture_*.json'));
    if isempty(entries)
        error('未找到 %s 下的 uart_capture_*.json，请先运行 UART 抓取脚本。', data_dir);
    end

    [~, idx] = max([entries.datenum]);
    json_file = fullfile(entries(idx).folder, entries(idx).name);
end


function [capture_prefix, raw_u16] = load_capture_samples(json_file, meta)
    json_path = string(json_file);
    json_dir = fileparts(json_path);

    if isfield(meta, 'bin_file')
        bin_path = string(meta.bin_file);
    else
        bin_path = "";
    end

    if strlength(bin_path) == 0 || ~isfile(bin_path)
        [~, stem, ~] = fileparts(json_path);
        bin_path = fullfile(json_dir, stem + ".bin");
    end

    if ~isfile(bin_path)
        error('采集二进制文件未找到: %s', bin_path);
    end

    fid = fopen(bin_path, 'rb');
    if fid < 0
        error('无法打开采集二进制文件: %s', bin_path);
    end
    cleaner = onCleanup(@() fclose(fid));
    raw_u16 = fread(fid, inf, 'uint16=>uint16', 0, 'ieee-le');

    if isfield(meta, 'sample_count') && numel(raw_u16) ~= meta.sample_count
        warning('样本数与 metadata 不一致: bin=%d, meta=%d', ...
            numel(raw_u16), meta.sample_count);
    end

    capture_prefix = erase(bin_path, ".bin");
end


function result = search_best_demod(bb, sps, skip_score_syms, fs_hz)
    gray_cycle = [0; 1; 3; 2];
    best.match_ratio = -inf;
    best.symbol_rms = -inf;

    for timing = 0:(sps-1)
        seq = bb((timing+1):end);
        num_sym = floor(numel(seq) / sps);
        if num_sym < 8
            continue;
        end

        sym = seq(1:sps:((num_sym-1) * sps + 1));
        sym = sym(:);
        for gray_shift = 0:3
            expected = gray_cycle(mod((0:num_sym-1)' + gray_shift, 4) + 1);
            expected_ref = ideal_qpsk_from_code(expected);
            [sym_aligned, fit] = align_symbols_to_reference(sym, expected_ref, fs_hz / sps);
            [bits, codes] = hard_decide_qpsk(sym_aligned);

            score_start = min(skip_score_syms + 1, num_sym);
            match = (codes(score_start:end) == expected(score_start:end));
            match_ratio = mean(match);
            symbol_rms = sqrt(mean(abs(sym_aligned) .^ 2));

            if match_ratio > best.match_ratio || ...
                    (abs(match_ratio - best.match_ratio) < 1e-12 && symbol_rms > best.symbol_rms)
                best.match_ratio = match_ratio;
                best.symbol_rms = symbol_rms;
                best.timing_offset = timing;
                best.gray_shift = gray_shift;
                best.num_symbols = num_sym;
                best.sym_raw = sym;
                best.sym_rot = sym_aligned;
                best.bits = bits;
                best.codes = codes;
                best.expected = expected;
                best.match = (codes == expected);
                best.phase_offset_deg = fit.phase_offset_deg;
                best.phase_slope_deg_per_sym = fit.phase_slope_deg_per_sym;
                best.cfo_hz = fit.cfo_hz;
                best.gain_est = fit.gain_est;
            end
        end
    end

    if ~isfinite(best.match_ratio)
        error('未找到有效的解调结果，请检查输入样本或参数。');
    end

    result = best;
end


function [bits, codes] = hard_decide_qpsk(sym)
    bit_i = real(sym) < 0;
    bit_q = imag(sym) < 0;
    bits = [bit_i bit_q];
    codes = bit_i + 2 * bit_q;
end


function ref = ideal_qpsk_from_code(code)
    ref = zeros(size(code));
    ref(code == 0) =  1 + 1j;
    ref(code == 1) = -1 + 1j;
    ref(code == 3) = -1 - 1j;
    ref(code == 2) =  1 - 1j;
    ref = ref / sqrt(2);
end


function [sym_aligned, fit] = align_symbols_to_reference(sym, ref, sym_rate_hz)
    n = (0:numel(sym)-1).';
    z = sym .* conj(ref);
    use = abs(z) > 1e-9;
    if nnz(use) < 4
        fit_phase = [0, 0];
    else
        fit_phase = polyfit(double(n(use)), unwrap(angle(z(use))), 1);
    end

    phase_track = fit_phase(1) * double(n) + fit_phase(2);
    sym_phase = sym .* exp(-1j * phase_track);
    gain_est = mean(sym_phase .* conj(ref));
    if abs(gain_est) < 1e-12
        gain_est = 1;
    end

    sym_aligned = sym_phase / gain_est;
    fit.phase_slope_deg_per_sym = fit_phase(1) * 180 / pi;
    fit.phase_offset_deg = fit_phase(2) * 180 / pi;
    fit.cfo_hz = fit_phase(1) / (2 * pi) * sym_rate_hz;
    fit.gain_est = gain_est;
end


function h = rrc_impulse_rrc(beta, sps, span_syms)
    t = (-span_syms/2 : 1/sps : span_syms/2).';
    h = zeros(size(t));

    for idx = 1:numel(t)
        ti = t(idx);
        if abs(ti) < 1e-12
            h(idx) = 1 + beta * (4 / pi - 1);
        elseif beta > 0 && abs(abs(ti) - 1 / (4 * beta)) < 1e-12
            h(idx) = (beta / sqrt(2)) * ...
                ((1 + 2 / pi) * sin(pi / (4 * beta)) + ...
                 (1 - 2 / pi) * cos(pi / (4 * beta)));
        else
            num = sin(pi * ti * (1 - beta)) + ...
                  4 * beta * ti * cos(pi * ti * (1 + beta));
            den = pi * ti * (1 - (4 * beta * ti)^2);
            h(idx) = num / den;
        end
    end

    h = h / sqrt(sum(abs(h).^2));
end


function export_demod_csv(capture_prefix, result)
    out_csv = capture_prefix + "_demod_symbols.csv";
    t = table( ...
        (0:result.num_symbols-1).', ...
        real(result.sym_rot), ...
        imag(result.sym_rot), ...
        result.bits(:, 1), ...
        result.bits(:, 2), ...
        result.codes, ...
        result.expected, ...
        result.match, ...
        'VariableNames', { ...
            'sym_idx', 'sym_i', 'sym_q', 'bit_i', 'bit_q', ...
            'sym_code', 'expected_code', 'is_match' ...
        });
    writetable(t, out_csv);
    fprintf('Saved decisions to: %s\n', out_csv);
end


function plot_demod_views(adc_signed, x, bb, result, fs_hz, carrier_hz, sps)
    n_use = min(numel(x), 16384);
    n_fft = 2^nextpow2(n_use);
    fft_win = 0.5 - 0.5 * cos(2 * pi * (0:n_use-1)' / max(n_use-1, 1));
    spec_in = fftshift(fft(x(1:n_use) .* fft_win, n_fft));
    freq_in = linspace(-fs_hz/2, fs_hz/2, n_fft) / 1e6;

    figure('Color', 'w', 'Name', 'QPSK UART Capture Demod');

    subplot(2,2,1);
    plot(adc_signed(1:min(2000, end)));
    grid on;
    xlabel('Sample Index');
    ylabel('ADC Code (centered)');
    title('ADC Samples');

    subplot(2,2,2);
    plot(freq_in, 20*log10(abs(spec_in) + 1e-12));
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Magnitude (dB)');
    title(sprintf('Spectrum (carrier ~= %.3f MHz)', carrier_hz / 1e6));

    subplot(2,2,3);
    plot(real(result.sym_rot), imag(result.sym_rot), '.');
    axis equal;
    grid on;
    xlabel('I');
    ylabel('Q');
    title(sprintf('Constellation (timing=%d, SPS=%d)', result.timing_offset, sps));

    subplot(2,2,4);
    stem(0:min(31, result.num_symbols-1), result.codes(1:min(32, end)), 'filled');
    hold on;
    stairs(0:min(31, result.num_symbols-1), result.expected(1:min(32, end)), 'LineWidth', 1.2);
    hold off;
    grid on;
    xlabel('Symbol Index');
    ylabel('Code');
    legend('Decided', 'Expected Gray', 'Location', 'best');
    title(sprintf('First Symbols, match ratio = %.4f', result.match_ratio));
end
