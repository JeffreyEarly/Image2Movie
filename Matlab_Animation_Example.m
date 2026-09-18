%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% 	Setup the parameters for the example
%
x=0:.01:10;
time=0:1:50;
c = -x(end)/time(end);
x0 = x(end);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% 	Select the folder where we shoudl put the animation frames
%	and create it, if necessary
%

FramesFolder = './Animation_Example_Frames';

if (length(time) > 1)
if exist(FramesFolder) == 0
	mkdir(FramesFolder);
end
end



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% 	Setup the figure
%

% Set the scale factor to 1, to get exactly the resolution of the figure.
% In this case that would be 1280x720. If you want something high quality,
% set the scale factor higher, then shrink it down later
ScaleFactor = 2;

figure('Position',[200 200 1280 720]);
set(gcf,'PaperPositionMode','auto')
set(gcf, 'Color', 'w');

for t=time
	
	% Extract the data
	f = exp( -(x-c*t-x0).*(x-c*t-x0) );

	% Plot it
	plot( x, f, '-r', 'LineWidth', 5);
	axis([x(1) x(end) 0 1.5]);
	set(gca, 'TickDir', 'out');
	set(gca, 'Linewidth', 2.0);
	set(gca, 'FontSize', 24.0);
	xlabel('Distance', 'FontName', 'Helvetica', 'FontSize', 24);
	ylabel('Amplitude', 'FontName', 'Helvetica', 'FontSize', 24);
	title('Propagating Signal', 'FontName', 'Helvetica', 'FontSize', 36);
	text( 1, 1.4, 1, sprintf('t = %.0f days',t), 'LineWidth', 2, 'FontName', 'Helvetica', 'FontSize', 36, 'BackgroundColor', 'white')
	
	% Now save it the folder
	if (length(time) > 1)
		%print(sprintf('-r%d',72*ScaleFactor), '-dpng', sprintf('%s/t_%03d', FramesFolder,t) );
		print('-depsc2', sprintf('%s/t_%03d', FramesFolder,t) );
	end
end


