//
//  ExamTableViewCell.swift
//  ViFi
//
//  Created by Emre Büyüker on 15.01.2023.
//

import UIKit

class ExamTableViewCell: UITableViewCell {

    @IBOutlet weak var examNameLabel: UILabel!
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
