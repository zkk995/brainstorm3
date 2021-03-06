function [sFile, ChannelMat] = in_fopen_intan(DataFile)
%% IN_FOPEN_INTAN Open Intan recordings.
%% Intan has 3 different ways of saving the raw file (Indicated by the AcqType variable throughout the code)
% 1. One .rhd file for saving everything
% 2. A separate file for each channel (.dat), a .rhd header, a separate
% file for each pin of the parallel port (.dat)
% 3. A separate file for each type of channel (one file for all data-files, one file for aux etc.)
% This code supports 1 and 2

% The events are read from a parallel port, and all Digital outputs are
% saved in seperate files as well.
% Information for the datatypes can be found at:
% http://intantech.com/files/Intan_RHD2000_data_file_formats.pdf

% 
% DESCRIPTION:
%     Reads all the following files available in the same folder.


% @=============================================================================
% This function is part of the Brainstorm software:
% https://neuroimage.usc.edu/brainstorm
% 
% Copyright (c)2000-2019 University of Southern California & McGill University
% This software is distributed under the terms of the GNU General Public License
% as published by the Free Software Foundation. Further details on the GPLv3
% license can be found at http://www.gnu.org/copyleft/gpl.html.
% 
% FOR RESEARCH PURPOSES ONLY. THE SOFTWARE IS PROVIDED "AS IS," AND THE
% UNIVERSITY OF SOUTHERN CALIFORNIA AND ITS COLLABORATORS DO NOT MAKE ANY
% WARRANTY, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF
% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, NOR DO THEY ASSUME ANY
% LIABILITY OR RESPONSIBILITY FOR THE USE OF THIS SOFTWARE.
%
% For more information type "brainstorm license" at command prompt.
% =============================================================================@
%
% Authors: Konstantinos Nasiotis 2018


%% ===== GET FILES =====
% Get base dataset folder
[hdr.BaseFolder, isItInfo] = bst_fileparts(DataFile);

if strcmp(isItInfo,'info')
    AcqType = 2; % One separate file per channel
else
    AcqType = 1; % One file to rule them all
end


if AcqType==2
    % Event files (.dat) % They are collected from a parallel port and saved as board-DIN-*.dat files
    EventFiles = dir(bst_fullfile(hdr.BaseFolder, '*DIN*.dat'));
    if isempty(EventFiles)
        disp(['BST> Warning: board-DIN-*.dat files not found in folder: ' 10 hdr.BaseFolder]);
        EventFiles = [];
    end
    % Recordings (*.ncs; *.nse)
    ampFiles = dir(bst_fullfile(hdr.BaseFolder, 'amp*.dat'));
    auxFiles = dir(bst_fullfile(hdr.BaseFolder, 'aux*.dat'));

    if isempty(ampFiles)
        error(['Could not find any .ncs recordings in folder: ' 10 hdr.BaseFolder]);
    end
    ChanFiles = sort({ampFiles.name, auxFiles.name});
end


%% ===== FILE COMMENT =====
% Get base folder name
[base_, dirComment, tmp] = bst_fileparts(hdr.BaseFolder);
% Comment: BaseFolder + number or files
Comment = dirComment;


%% ===== READ DATA HEADERS =====
hdr.chan_headers = {};
hdr.chan_files = {};

% Read the header
newHeader = read_Intan_RHD2000_file(DataFile,1,1,1,100);
newHeader.AcqType = AcqType; % This will be used later in in_fread_intan.m

% Check for the magic Number
if newHeader.magic_number ~= hex2dec('c6912702')
    error('Magic Number Incorrect. The Intan header was not loaded properly');
end

% Check for some important fields
if ~isfield(newHeader, 'frequency_parameters') || ~isfield(newHeader, 'amplifier_channels') || ~isfield(newHeader, 'sample_rate')
    error('Missing fields in the file header of file');
end

% Check if all the channels' files are present
if AcqType==2
    if length(ampFiles) ~= newHeader.num_amplifier_channels
        error('Missing channel files. Check if the .dat files from all channels are present');
    end
    % Check if there are missing timestamps in the file
    % Check from the time.dat file how many samples exist, and compare with
    % every amp file that was collected
    fileinfo = dir(fullfile(base_,dirComment,'time.dat'));
    num_samples_time = fileinfo.bytes/4; % int32 = 4 bytes
    for iChannel = 1:newHeader.num_amplifier_channels
        num_samples_channel = ampFiles(iChannel).bytes/2; % int32 = 4 bytes
        if (num_samples_time ~= num_samples_channel)
            error(['There are some missing blocks of recordings in file: ' ampFiles(iChannel).name]);
        end
    end
    % Read the time.dat file to extract first and last timestamp
    fid = fopen(fullfile(base_,dirComment,'time.dat'), 'r');
    Time = fread(fid, num_samples_time, 'int32');
    fclose(fid);
    Time = Time / newHeader.frequency_parameters.amplifier_sample_rate; % sample rate from header file

    hdr.chan_files   = ampFiles;  % I ONLY LOAD THE AMP FILES HERE. THE AUXILIARY FILES HAVE DIFFERENT SAMPLING FREQUENCY. FIX THIS ON A LATER VERSION
    hdr.ChannelCount = length(hdr.chan_files);
    hdr.NumSamples   = num_samples_time;

else
    Time             = linspace(0,newHeader.nSamples/newHeader.sample_rate,newHeader.nSamples);
    num_samples_time = newHeader.sample_rate;
    hdr.ChannelCount = newHeader.num_amplifier_channels;
    hdr.NumSamples   = newHeader.nSamples;
end



% Extract information needed for opening the file
hdr.FirstTimeStamp        = Time(1);
hdr.LastTimeStamp         = Time(end);
hdr.SamplingFrequency     = newHeader.sample_rate;


% Save all file names
hdr.chan_headers = newHeader;
hdr.DataFile     = DataFile;

[tmp, folderName] = bst_fileparts(hdr.BaseFolder);

%% ===== CREATE BRAINSTORM SFILE STRUCTURE =====
% Initialize returned file structure
sFile = db_template('sfile');
% Add information read from header
sFile.byteorder = 'l';
sFile.filename  = hdr.BaseFolder;
sFile.format    = 'EEG-INTAN';
sFile.device    = 'Intan';
sFile.header    = hdr;
sFile.comment   = Comment;
sFile.condition = folderName;
% Consider that the sampling rate of the file is the sampling rate of the first signal
sFile.prop.sfreq   = hdr.SamplingFrequency;
sFile.prop.samples = [0, hdr.NumSamples - 1];
sFile.prop.times   = sFile.prop.samples ./ sFile.prop.sfreq;
sFile.prop.nAvg    = 1;
% No info on bad channels
sFile.channelflag = ones(hdr.ChannelCount, 1);


%% ===== CREATE EMPTY CHANNEL FILE =====
ChannelMat = db_template('channelmat');
ChannelMat.Comment = 'Intan channels';
ChannelMat.Channel = repmat(db_template('channeldesc'), [1, hdr.ChannelCount]);
% For each channel
for i = 1:hdr.ChannelCount
    if AcqType==2
        [fPath,fName,fExt] = bst_fileparts(hdr.chan_files(i).name);
        ChannelMat.Channel(i).Name = fName;
    else
        ChannelMat.Channel(i).Name = newHeader.amplifier_channels(i).custom_channel_name;
    end
    ChannelMat.Channel(i).Loc     = [0; 0; 0];
    ChannelMat.Channel(i).Type    = 'EEG';
    ChannelMat.Channel(i).Orient  = [];
    ChannelMat.Channel(i).Weight  = 1;
    ChannelMat.Channel(i).Comment = [];
end


%% ===== READ EVENTS =====
areThereEvents = 0;

if AcqType==2
    if ~isempty(EventFiles)
        % Read blocks of BINARY INPUT channels to create events
        parallel_input = false(num_samples_time, length(EventFiles));

        for iDIN = 1:length(EventFiles)
            fid = fopen(fullfile(base_,dirComment,EventFiles(iDIN).name), 'r');        
            temp = fread(fid, num_samples_time, 'uint16');
            parallel_input(:,iDIN) = logical(temp);
            fclose(fid);
        end
        events_vector = bst_bi2de(parallel_input,'right-msb'); % Collapse the parallel ports to a vector that shows the events
        areThereEvents = 1;
    end
else
    if isfield(newHeader,'board_dig_in_data')
        events_vector = bst_bi2de(newHeader.board_dig_in_data,'right-msb'); % Collapse the parallel ports to a vector that shows the events
        areThereEvents = 1;
    end
end

if areThereEvents
    if bst_get('UseSigProcToolbox')
        [event_labels, event_samples] = findpeaks(events_vector);
    else
        [event_samples, event_labels] = peakseek(events_vector, min(events_vector));
        event_labels = event_labels';
        event_samples = event_samples';
    end
    
    % Create events list
    if ~isempty(event_labels)
        
        % Get list of events
        event_labels_unique = unique(event_labels); % These are still numbers
        
        % Initialize list of events
        events = repmat(db_template('event'), 1, length(event_labels_unique));
        % Format list
        for iEvt = 1:length(event_labels_unique)
            % Fill the event fields
            events(iEvt).label      = num2str(event_labels_unique(iEvt));
            events(iEvt).color      = rand(1,3);
            events(iEvt).reactTimes = [];
            events(iEvt).select     = 1;
            
            % Set time
            events(iEvt).samples = event_samples(event_labels == event_labels_unique(iEvt))';
            % Convert to time
            events(iEvt).times = events(iEvt).samples ./ sFile.prop.sfreq;
            % Epoch: set as 1 for all the occurrences
            events(iEvt).epochs = ones(1, length(events(iEvt).samples));
        end
        % Import this list
        sFile = import_events(sFile, [], events);
    end
end
end


function de = bst_bi2de(bi, flg)
    if nargin < 2 || isempty(flg)
        flg = 'right-msb';
    end

    % Call toolbox function if available
    if exist('bi2de', 'file') == 2
        de = bi2de(bi, flg);
        return;
    end

    % Initialize array of powers of two
    [numElems, numDecimals] = size(bi);
    pows = zeros(numDecimals, 1);
    for iDec = 1:numDecimals
        pows(iDec) = 2 ^ (iDec - 1);
    end
    
    % Flip if required
    if strcmp(flg, 'left-msb')
        pows = flipud(pows);
    end
    
    de = bi * pows;
end

