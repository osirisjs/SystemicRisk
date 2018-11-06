% [INPUT]
% data = A structure representing the dataset.
% res  = A string representing the full path to the Excel spreadsheet to which the results are written, eventually replacing the previous ones.
% sst  = A float representing he statistical significance threshold for the linear Granger-causality test (optional, default=0.05).
% rob  = A boolean indicating whether to use robust p-values (optional, default=true).
% anl  = A boolean that indicates whether to analyse the results (optional, default=false).

function main_net(varargin)

    persistent p;

    if (isempty(p))
        p = inputParser();
        p.addRequired('data',@(x)validateattributes(x,{'struct'},{'nonempty'}));
        p.addRequired('res',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        p.addOptional('sst',0.05,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>',0,'<=',0.20}));
        p.addOptional('rob',true,@(x)validateattributes(x,{'logical'},{'scalar'}));
        p.addOptional('anl',false,@(x)validateattributes(x,{'logical'},{'scalar'}));
    end

    p.parse(varargin{:});
    res = p.Results;

    [path,name,ext] = fileparts(res.res);

    if (~strcmp(ext,'.xlsx'))
        res = fullfile(path,[name ext '.xlsx']);
    end
    
    main_net_internal(res.data,res.res,res.sst,res.rob,res.anl);

end

function main_net_internal(data,res,sst,rob,anl)

    data = update_data(data,sst,rob);

    win = get_rolling_windows(data.FrmsRet,252);
    win_len = length(win);
    win_dif = data.Obs - win_len;

    bar = waitbar(0,'Calculating network measures...','CreateCancelBtn','setappdata(gcbf,''Stop'',true)');
    setappdata(bar,'Stop',false);
    
    try
        for i = 1:win_len
            waitbar(((i - 1) / win_len),bar,sprintf('Calculating network measures for window %d of %d...',i,win_len));
            
            if (getappdata(bar,'Stop'))
                delete(bar);
                return;
            end
            
            win_i = win{i,1};
            win_i_nor = win_i;
            win_off = i + win_dif;

            for j = 1:size(win_i_nor,2)
                win_ij_nor = win_i_nor(:,j);
                win_ij_nor = win_ij_nor - nanmean(win_ij_nor);
                win_i_nor(:,j) = win_ij_nor / nanstd(win_ij_nor);
            end
            
            win_i_nor(isnan(win_i_nor)) = 0;

            adjm = calculate_adjacency_matrix(win_i,data.SST,data.Rob);
            [dci,n_io,n_ioo,clo_cen,clu_cen,deg_cen,eig_cen] = calculate_measures(adjm,data.GrpsDel);
            [pca_coe,pca_sco,~,~,pca_exp] = pca(win_i_nor,'Economy',false);

            data.AdjMats{win_off} = adjm;
            data.CloCen(win_off,:) = clo_cen;
            data.CluCoe(win_off,:) = clu_cen;
            data.DCI(win_off) = dci;
            data.DegCen(win_off,:) = deg_cen;
            data.EigCen(win_off,:) = eig_cen;
            data.NumIO(win_off) = n_io;
            data.NumIOO(win_off) = n_ioo;
            data.PCACoe{win_off} = pca_coe;
            data.PCAExp{win_off} = pca_exp;
            data.PCASco{win_off} = pca_sco;

            if (getappdata(bar,'Stop'))
                delete(bar);
                return;
            end
            
            waitbar((i / win_len),bar,sprintf('Calculating network measures for window %d of %d...',i,win_len));
        end

        data = update_data(data,win_dif);

        waitbar(100,bar,'Writing network measures...');
        write_results(res,data);
        
        delete(bar);
        
        if (anl)        
            plot_indices(data);
            plot_network(data);
            plot_centralities(data);
            plot_pca(data);
        end
    catch e
        delete(bar);
        rethrow(e);
    end

end

function data = update_data(data,arg_1,arg_2)

    if (nargin == 3)
        data.SST = arg_1;
        data.Rob = arg_2;

        data.AdjMats = cell(data.Obs,1);
        data.CloCen = NaN(data.Obs,data.Frms);
        data.CluCoe = NaN(data.Obs,data.Frms);
        data.DCI = NaN(data.Obs,1);
        data.DegCen = NaN(data.Obs,data.Frms);
        data.EigCen = NaN(data.Obs,data.Frms);
        data.NumIO = NaN(data.Obs,1);
        data.NumIOO = NaN(data.Obs,1);
        data.PCACoe = cell(data.Obs,1);
        data.PCAExp = cell(data.Obs,1);
        data.PCASco = cell(data.Obs,1);
    else
        data.WinOff = arg_1 + 1;
        
        win_seq =  data.WinOff:data.Obs;
        win_seq_len = length(win_seq);

        data.AdjMatAvg = sum(cat(3,data.AdjMats{win_seq}),3) ./ win_seq_len;
        thre = mean(mean(data.AdjMatAvg));
        data.AdjMatAvg(data.AdjMatAvg < thre) = 0;
        data.AdjMatAvg(data.AdjMatAvg >= thre) = 1;

        data.CloCenAvg = sum(data.CloCen(win_seq,:),1) ./ win_seq_len;
        data.CluCoeAvg = sum(data.CluCoe(win_seq,:),1) ./ win_seq_len;
        data.DegCenAvg = sum(data.DegCen(win_seq,:),1) ./ win_seq_len;
        data.EigCenAvg = sum(data.EigCen(win_seq,:),1) ./ win_seq_len;

        data.PCACoeAvg = sum(cat(3,data.PCACoe{win_seq}),3) ./ length(win_seq);
        data.PCAExpAvg = sum(cat(3,data.PCAExp{win_seq}),3) ./ length(win_seq);
        data.PCAExpSum = NaN(data.Obs,4);
        data.PCAScoAvg = sum(cat(3,data.PCASco{win_seq}),3) ./ length(win_seq);

        for i = win_seq
            exp = data.PCAExp{i};
            data.PCAExpSum(i,:) = fliplr([cumsum([exp(1) exp(2) exp(3)]) 100]);
        end
    end

end

function write_results(res,data)

    [res_path,~,~] = fileparts(res);

    if (exist(res_path,'dir') ~= 7)
        mkdir(res_path);
    end

    if (exist(res,'file') == 2)
        delete(res);
    end

    frms = data.FrmsNam';
    sep = repmat({' '},data.Frms,1);
    
    ind = cell2table([data.DatesStr num2cell(data.DCI) num2cell(data.NumIO) num2cell(data.NumIOO)],'VariableNames',{'Date' 'DCI' 'NumIO' 'NumIOO'});

    vars = [frms num2cell(data.AdjMatAvg) sep frms num2cell(data.CloCenAvg') num2cell(data.CluCoeAvg') num2cell(data.DegCenAvg') num2cell(data.EigCenAvg')];
    lbls = {'Firms1' data.FrmsNam{:,:} 'E' 'Firms2' 'CloCen' 'CluCoe' 'DegCen' 'EigCen'};
    net = cell2table(vars,'VariableNames',lbls);
 
    vars = [frms num2cell(data.PCACoeAvg) sep num2cell(1:data.Frms)' num2cell(data.PCAExpAvg)];
    lbls = {'Firms' data.FrmsNam{:,:} 'E' 'PC' 'ExpVar'};
    pca_1 = cell2table(vars,'VariableNames',lbls);
    
    pca_2 = cell2table(num2cell(data.PCAScoAvg),'VariableNames',data.FrmsNam);
    
    writetable(ind,res,'FileType','spreadsheet','Sheet',1,'WriteRowNames',true);
    writetable(net,res,'FileType','spreadsheet','Sheet',2,'WriteRowNames',true);   
    writetable(pca_1,res,'FileType','spreadsheet','Sheet',3,'WriteRowNames',true); 
    writetable(pca_2,res,'FileType','spreadsheet','Sheet',4,'WriteRowNames',false);
    
    exc = actxserver('Excel.Application');
    exc_wbs = exc.Workbooks.Open(res,0,false);
    exc_wbs.Sheets.Item(1).Name = 'Indices';
    exc_wbs.Sheets.Item(2).Name = 'Network Averages';
    exc_wbs.Sheets.Item(3).Name = 'PCA Average Coefficients';
    exc_wbs.Sheets.Item(4).Name = 'PCA Average Scores';
    exc_wbs.Save();
    exc_wbs.Close();
    exc.Quit();

end

function plot_indices(data)

    fig = figure('Name','Measures of Connectedness','Units','normalized','Position',[100 100 0.85 0.85]);

    sub_1 = subplot(2,1,1);
    plot(sub_1,data.DatesNum,data.DCI);
    datetick(sub_1,'x','yyyy','KeepLimits');
    t1 = title(sub_1,'Dynamic Causality Index');
    set(t1,'Units','normalized');
    t1_pos = get(t1,'Position');
    set(t1,'Position',[0.4783 t1_pos(2) t1_pos(3)]);

    sub_2 = subplot(2,1,2);
    ar_1 = area(sub_2,data.DatesNum,data.NumIO,'EdgeColor','none','FaceColor','b');
    hold on;
        if (data.Grps == 0)
            ar_2 = area(sub_2,data.DatesNum,data.NumIO,'EdgeColor','none','FaceColor',[0.678 0.922 1]);
            area(sub_2,data.DatesNum,data.NumIO,'EdgeColor','none','FaceColor','b');
        else
            ar_2 = area(sub_2,data.DatesNum,data.NumIOO,'EdgeColor','none','FaceColor',[0.678 0.922 1]);
        end
    hold off;
    datetick(sub_2,'x','yyyy','KeepLimits');
    legend(sub_2,[ar_1 ar_2],'Num IO','Num IOO','Location','northwest');
    t2 = title(sub_2,'In & Out Connections');
    set(t2,'Units','normalized');
    t2_pos = get(t2,'Position');
    set(t2,'Position',[0.4783 t2_pos(2) t2_pos(3)]);

    set([sub_1 sub_2],'XLim',[data.DatesNum(data.WinOff) data.DatesNum(end)],'XTickLabelRotation',45);

    t = figure_title('Measures of Connectedness');
    t_pos = get(t,'Position');
    set(t,'Position',[t_pos(1) -0.0157 t_pos(3)]);

    pause(0.01);

    jfr = get(fig,'JavaFrame');
    set(jfr,'Maximized',true);

end

function plot_network(data)

    if (data.Grps == 0)
        grps_col = repmat(lines(1),data.Frms,1);
    else
        grps_col = zeros(data.Frms,3);
        grps_del_len = length(data.GrpsDel);
        grps_del_plu = data.GrpsDel + 1;
        grps_lin = lines(data.Grps);

        for i = 1:grps_del_len
            del = data.GrpsDel(i);

            if (i == 1)
                grps_col(1:del,:) = repmat(grps_lin(i,:),del,1);
            else
                del_prev = data.GrpsDel(i-1) + 1;
                grps_col(del_prev:del,:) = repmat(grps_lin(i,:),del-del_prev+1,1);
            end

            if (i == grps_del_len)
                grps_col(del+1:end,:) = repmat(grps_lin(i+1,:),data.Frms-del,1);
            end
        end
    end
    
    wei = mean(data.FrmsCap,1);
    wei = wei ./ mean(wei);
    
    theta = linspace(0,(2 * pi),(data.Frms + 1))';
    theta(end) = [];
    xy = [cos(theta) sin(theta)];
    [i,j] = find(data.AdjMatAvg);
    [~,idxs] = sort(max(i,j));
    i = i(idxs);
    j = j(idxs);
    x = [xy(i,1) xy(j,1)]';
    y = [xy(i,2) xy(j,2)]';

    fig = figure('Name','Network Graph','Units','normalized','Position',[100 100 0.85 0.85]);

    sub = subplot(100,1,10:100);
    
    hold on;
        for i = 1:size(x,2)
            idx = ismember(xy,[x(1,i) y(1,i)],'rows');
            plot(sub,x(:,i),y(:,i),'Color',grps_col(idx,:));
        end

        if (data.Grps == 0)
            for i = 1:size(xy,1)
                line(xy(i,1),xy(i,2),'Color',grps_col(i,:),'LineStyle','none','Marker','.','MarkerSize',(35 + (15 * wei(i))));
            end
        else
            lins = NaN(data.Grps,1);
            lins_off = 1;
            
            for i = 1:size(xy,1)
                grps_col_i = grps_col(i,:);
                line(xy(i,1),xy(i,2),'Color',grps_col_i,'LineStyle','none','Marker','.','MarkerSize',(35 + (15 * wei(i))));

                if ((i == 1) || any(grps_del_plu == i))
                    lins(lins_off) = line(xy(i,1),xy(i,2),'Color',grps_col_i,'LineStyle','none','Marker','.','MarkerSize',35);
                    lins_off = lins_off + 1;
                end
            end

            legend(sub,lins,data.GrpsNam,'Units','normalized','Position',[0.85 0.12 0.001 0.001]);
        end

        axis(sub,[-1 1 -1 1]);
        axis equal off;
    hold off;

    txts = text((xy(:,1) .* 1.05), (xy(:,2) .* 1.05),data.FrmsNam,'FontSize',10);
    set(txts,{'Rotation'},num2cell(theta * (180 / pi)));

    t = figure_title('Network Graph');
    t_pos = get(t,'Position');
    set(t,'Position',[t_pos(1) -0.0157 t_pos(3)]);
    
    pause(0.01);

    jfr = get(fig,'JavaFrame');
    set(jfr,'Maximized',true);

end

function plot_centralities(data)

    seq = 1:data.Frms;
    seq_lim = [0 (data.Frms + 1)];
    
    [cloc_sor,ord] = sort(data.CloCenAvg);
    cloc_nam = data.FrmsNam(ord);
    [cluc_sor,ord] = sort(data.CluCoeAvg);
    cluc_nam = data.FrmsNam(ord);
    [degc_sor,ord] = sort(data.DegCenAvg);
    degc_nam = data.FrmsNam(ord);
    [eigc_sor,ord] = sort(data.EigCenAvg);
    eigc_nam = data.FrmsNam(ord);    

    fig = figure('Name','Average Centrality Coefficients','Units','normalized','Position',[100 100 0.85 0.85]);

    sub_1 = subplot(2,2,1);
    bar(sub_1,seq,cloc_sor,'FaceColor',[0.678 0.922 1]);
    set(sub_1,'XTickLabel',cloc_nam);
    title('Closeness Centrality');

    sub_2 = subplot(2,2,2);
    bar(sub_2,seq,cluc_sor,'FaceColor',[0.678 0.922 1]);
    set(sub_2,'XTickLabel',cluc_nam);
    title('Clustering Coefficient');
    
    sub_3 = subplot(2,2,3);
    bar(sub_3,seq,degc_sor,'FaceColor',[0.678 0.922 1]);
    set(sub_3,'XTickLabel',degc_nam);
    title('Degree Centrality');
    
    sub_4 = subplot(2,2,4);
    bar(sub_4,seq,eigc_sor,'FaceColor',[0.678 0.922 1]);
    set(sub_4,'XTickLabel',eigc_nam);
    title('Eigenvector Centrality');
    
    set([sub_1 sub_2 sub_3 sub_4],'XLim',seq_lim,'XTick',seq,'XTickLabelRotation',90);

    t = figure_title('Average Centrality Coefficients');
    t_pos = get(t,'Position');
    set(t,'Position',[t_pos(1) -0.0157 t_pos(3)]);
    
    pause(0.01);

    jfr = get(fig,'JavaFrame');
    set(jfr,'Maximized',true);

end

function plot_pca(data)

    coe = data.PCACoeAvg(:,1:3);
    [coe_rows,coe_cols] = size(coe);

    sco = data.PCAScoAvg(:,1:3);
    sco_rows = size(sco,1);
    
    [~,idx] = max(abs(coe),[],1);
    coe_max_len = sqrt(max(sum(coe.^2,2)));
    cols_sig = sign(coe(idx + (0:coe_rows:((coe_cols-1)*coe_rows))));

    coe = bsxfun(@times,coe,cols_sig);
    sco = bsxfun(@times,(coe_max_len .* (sco ./ max(abs(sco(:))))),cols_sig);
    
    ar_beg = zeros(coe_rows,1);
    ar_end = NaN(coe_rows,1);
    x_ar = [ar_beg coe(:,1) ar_end]';
    y_ar = [ar_beg coe(:,2) ar_end]';
    z_ar = [ar_beg coe(:,3) ar_end]';
    
    ar_end = NaN(sco_rows,1);
    x_pts = [sco(:,1) ar_end]';
    y_pts = [sco(:,2) ar_end]';
    z_pts = [sco(:,3) ar_end]';

    lim_hi = 1.1 * max(abs(coe(:)));
    lim_lo = -lim_hi;
    
    y_tcks = 0:10:100;
    y_lbls = arrayfun(@(x)sprintf('%d%%',x),y_tcks,'UniformOutput',false);
    
    fig = figure('Name','Principal Component Analysis','Units','normalized');

    sub_1 = subplot(1,2,1);
    lin_1 = line(x_ar(1:2,:),y_ar(1:2,:),z_ar(1:2,:),'LineStyle','-','Marker','none');
    lin_2 = line(x_ar(2:3,:),y_ar(2:3,:),z_ar(2:3,:),'LineStyle','none','Marker','.');
    set([lin_1 lin_2],'Color','b');
    line(x_pts,y_pts,z_pts,'Color','r','LineStyle','none','Marker','.');
    view(sub_1,coe_cols);
    grid on;
    line([lim_lo lim_hi NaN 0 0 NaN 0 0],[0 0 NaN lim_lo lim_hi NaN 0 0],[0 0 NaN 0 0 NaN lim_lo lim_hi],'Color','k');
    axis tight;
    xlabel(sub_1,'PC 1');
    ylabel(sub_1,'PC 2');
    zlabel(sub_1,'PC 3');
    title('Coefficients & Scores');

    sub_2 = subplot(1,2,2);
    ar_1 = area(sub_2,data.DatesNum,data.PCAExpSum(:,1),'FaceColor',[0.7 0.7 0.7]);
    hold on;
        ar_2 = area(sub_2,data.DatesNum,data.PCAExpSum(:,2),'FaceColor','g');
        ar_3 = area(sub_2,data.DatesNum,data.PCAExpSum(:,3),'FaceColor','b');
        ar_4 = area(sub_2,data.DatesNum,data.PCAExpSum(:,4),'FaceColor','r');
    hold off;
    datetick('x','yyyy','KeepLimits');
    set([ar_1 ar_2 ar_3 ar_4],'EdgeColor','none');
    set(sub_2,'XLim',[data.DatesNum(data.WinOff) data.DatesNum(end)],'YLim',[y_tcks(1) y_tcks(end)],'YTick',y_tcks,'YTickLabel',y_lbls);
    legend(sub_2,sprintf('PC 4-%d',data.Frms),'PC 3','PC 2','PC 1','Location','southeast');
    title('Explained Variance');

    t = figure_title('Principal Component Analysis');
    t_pos = get(t,'Position');
    set(t,'Position',[t_pos(1) -0.0157 t_pos(3)]);
    
    pause(0.01);

    jfr = get(fig,'JavaFrame');
    set(jfr,'Maximized',true);

end
