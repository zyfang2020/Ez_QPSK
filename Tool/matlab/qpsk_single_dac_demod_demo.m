% qpsk_single_dac_demod_demo.m
% 读取 Verilog 导出的单 DAC 采样（offset-binary），做一个最小 QPSK 离线解调演示。

clear; clc;

% ===== 参数（与 tb_qpsk_tx_single_dac_min.v 保持一致） =====
csv_candidates = {
    '../../Ez_QPSK.sim/sim_1/behav/xsim/qpsk_single_dac_samples_gray.csv'
    '../../Ez_QPSK.sim/sim_1/behav/xsim/qpsk_single_dac_samples.csv'
};
csv_file = '';
for k = 1:numel(csv_candidates)
    if isfile(csv_candidates{k})
        csv_file = csv_candidates{k};
        break;
    end
end
if isempty(csv_file)
    error('CSV 未找到，请检查 xsim 输出目录。');
end
DAC_DW    = 12;
PHASE_INC = hex2dec('180000');
SPS       = 50;
SKIP_SAMPLES = 300; % 跳过起始过渡段样点数，可按需要调整

% ===== 读数据 =====
m = readmatrix(csv_file);
if size(m,2) < 2
    error('CSV 列数不足，期望两列: idx,dac_u12');
end
u = m(:,2);  % unsigned offset-binary code

if length(u) <= SKIP_SAMPLES
    error('样本数(%d) <= SKIP_SAMPLES(%d)，请减小 SKIP_SAMPLES。', length(u), SKIP_SAMPLES);
end
u = u(SKIP_SAMPLES+1:end);

% ===== offset-binary -> signed (two''s complement value) =====
offset = 2^(DAC_DW-1);
x = bitxor(uint16(u), uint16(offset));
x = double(x);
hi = x >= offset;
x(hi) = x(hi) - 2^DAC_DW;

% ===== 数字下变频（已知 NCO 频率） =====
n = (0:length(x)-1).';
f_c = double(PHASE_INC) / 2^24;   % cycles/sample
lo = exp(-1j*2*pi*f_c*n);
bb = x .* lo;

% ===== 简单匹配：积分抽样（每 SPS 点取平均） =====
num_sym = floor(length(bb)/SPS);
bb = bb(1:num_sym*SPS);
bb_mat = reshape(bb, SPS, num_sym);
sym = mean(bb_mat, 1).';

% ===== 判决 =====
I = real(sym);
Q = imag(sym);
bitI = I < 0;
bitQ = Q < 0;

% Gray 映射（与你 mapper 对齐时可调整）
% 这里给出常见一种：
% 00 -> (+,+), 01 -> (-,+), 11 -> (-,-), 10 -> (+,-)
sym_bits = [bitI bitQ];

% ===== 可视化 =====
figure('Color','w');
subplot(1,2,1);
plot(x(1:min(2000,end)));
grid on; title('DAC signed samples (time)');
xlabel('n'); ylabel('amplitude');

subplot(1,2,2);
plot(I, Q, '.'); axis equal; grid on;
title('Constellation after DDC + integrate');
xlabel('I'); ylabel('Q');

fprintf('Loaded %d samples (after skip %d), recovered %d symbols.\\n', length(x), SKIP_SAMPLES, length(sym));
fprintf('First 8 decided bits [I<0, Q<0]:\\n');
disp(sym_bits(1:min(8,end),:));
