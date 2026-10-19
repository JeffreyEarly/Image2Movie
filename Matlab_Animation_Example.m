%% Generate lossless PNG frames for Image2Movie (MATLAB R2025a or newer).
% Import the frames in filename order, then export at 1920 x 1080 and 30 fps.
% The 120 frames make a four-second movie in Image2Movie 3.1 or 4.0.

%% Choose the output size, timing, and an empty folder.
frameWidth = 1920;
frameHeight = 1080;
frameRate = 30;
duration = 4;
frameCount = frameRate * duration;
outputFolder = fullfile(pwd, "Animation_Example_Frames");
if ~isempty(dir(fullfile(outputFolder, "*.png")))
    error("Choose an empty outputFolder to avoid mixing old and new frames.");
end
mkdir(outputFolder);

%% Create the plot once, with fixed axes and a white background.
x = linspace(0, 10, 1000);
fig = figure(Units="pixels", Position=[100 100 960 540], Theme="light");
ax = axes(fig, FontSize=14);
signal = plot(ax, x, zeros(size(x)), LineWidth=3, Color=[0.1 0.4 0.7]);
xlim(ax, [0 10]);
ylim(ax, [0 1.2]);
xlabel(ax, "Distance");
ylabel(ax, "Amplitude");
title(ax, "A traveling pulse");

%% Update the data and export each frame at exact pixel dimensions.
for frameIndex = 1:frameCount
    time = (frameIndex - 1) / frameRate;
    center = 2 + 6 * time / duration;
    signal.YData = exp(-((x - center) / 0.6).^2);
    filename = fullfile(outputFolder, sprintf("frame_%04d.png", frameIndex));
    exportgraphics(fig, filename, Units="pixels", Width=frameWidth, Height=frameHeight, Padding="figure", BackgroundColor="white");
end
fprintf("Wrote %d frames to %s\n", frameCount, outputFolder);
